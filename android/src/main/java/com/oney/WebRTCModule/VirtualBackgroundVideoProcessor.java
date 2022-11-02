package com.oney.WebRTCModule;

import static android.graphics.Color.argb;
import static android.graphics.PorterDuff.Mode.DST_OVER;
import static android.graphics.PorterDuff.Mode.SRC_IN;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.graphics.PorterDuffXfermode;
import android.opengl.GLES20;
import android.opengl.GLUtils;

import androidx.annotation.Nullable;

import com.facebook.react.bridge.ReactApplicationContext;
import com.google.android.gms.tasks.OnSuccessListener;
import com.google.android.gms.tasks.Task;
import com.google.mlkit.vision.common.InputImage;
import com.google.mlkit.vision.segmentation.Segmentation;
import com.google.mlkit.vision.segmentation.SegmentationMask;
import com.google.mlkit.vision.segmentation.Segmenter;
import com.google.mlkit.vision.segmentation.selfie.SelfieSegmenterOptions;

import org.webrtc.SurfaceTextureHelper;
import org.webrtc.TextureBufferImpl;
import org.webrtc.VideoFrame;
import org.webrtc.VideoProcessor;
import org.webrtc.VideoSink;
import org.webrtc.YuvConverter;

public class VirtualBackgroundVideoProcessor implements VideoProcessor {

    private VideoSink target;
    private final SurfaceTextureHelper surfaceTextureHelper;
    final YuvConverter yuvConverter = new YuvConverter();

    private YuvFrame yuvFrame;
    private Bitmap inputFrameBitmap;
    private int frameCounter = 0;

    final Bitmap backgroundImage;
    final Bitmap scaled;

    final SelfieSegmenterOptions options =
        new SelfieSegmenterOptions.Builder()
            .setDetectorMode(SelfieSegmenterOptions.STREAM_MODE)
            .build();
    final Segmenter segmenter = Segmentation.getClient(options);

    public VirtualBackgroundVideoProcessor(ReactApplicationContext context, SurfaceTextureHelper surfaceTextureHelper) {
        super();

        this.surfaceTextureHelper = surfaceTextureHelper;

        backgroundImage = BitmapFactory.decodeResource(context.getResources(), R.drawable.portrait_background);
        scaled = Bitmap.createScaledBitmap(backgroundImage, 640, 640, false );
    }

    @Override
    public void setSink(@Nullable VideoSink videoSink) {
        target = videoSink;
    }

    @Override
    public void onCapturerStarted(boolean b) {

    }

    @Override
    public void onCapturerStopped() {

    }

    @Override
    public void onFrameCaptured(VideoFrame videoFrame) {

        if(frameCounter == 0) {
            yuvFrame = new YuvFrame(videoFrame);
            inputFrameBitmap = yuvFrame.getBitmap();

            InputImage image = InputImage.fromBitmap(inputFrameBitmap, 0);

            Task<SegmentationMask> result =
                segmenter.process(image)
                    .addOnSuccessListener(
                        new OnSuccessListener<SegmentationMask>() {
                            @Override
                            public void onSuccess(SegmentationMask mask) {

                                mask.getBuffer().rewind();
                                int[] arr = maskColorsFromByteBuffer(mask);
                                Bitmap segmentedBitmap = Bitmap.createBitmap(
                                    arr, mask.getWidth(), mask.getHeight(), Bitmap.Config.ARGB_8888
                                );
                                arr = null;

                                Bitmap segmentedBitmapMutable = segmentedBitmap.copy(Bitmap.Config.ARGB_8888, true);
                                segmentedBitmap.recycle();
                                Canvas canvas = new Canvas(segmentedBitmapMutable);

                                Paint paint = new Paint();
                                paint.setXfermode(new PorterDuffXfermode(SRC_IN));
                                canvas.drawBitmap(scaled, 0, 0, paint);
                                paint.setXfermode(new PorterDuffXfermode(DST_OVER));
                                canvas.drawBitmap(inputFrameBitmap, 0, 0, paint);

                                surfaceTextureHelper.getHandler().post(new Runnable() {
                                    @Override
                                    public void run() {

                                        GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
                                        TextureBufferImpl buffer = new TextureBufferImpl(segmentedBitmapMutable.getWidth(),
                                            segmentedBitmapMutable.getHeight(), VideoFrame.TextureBuffer.Type.RGB,
                                            GLES20.GL_TEXTURE0, new Matrix(), surfaceTextureHelper.getHandler(), yuvConverter, null);
                                        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE0);

                                        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST);
                                        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_NEAREST);
                                        GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, segmentedBitmapMutable, 0);
                                        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0);

                                        VideoFrame.I420Buffer i420Buf = yuvConverter.convert(buffer);
                                        VideoFrame out = new VideoFrame(i420Buf, 180, videoFrame.getTimestampNs());

                                        buffer.release();
                                        //yuvFrame.dispose();

                                        target.onFrame(out);
                                        out.release();
                                    }
                                });

                            }
                        });
        }
        updateFrameCounter();
    }

    private void updateFrameCounter() {
        frameCounter++;
        if(frameCounter == 3) {
            frameCounter = 0;
        }
    }

    private int[] maskColorsFromByteBuffer(SegmentationMask mask) {
        int[] colors = new int[mask.getHeight() * mask.getWidth()];
        for (int i = 0; i < mask.getHeight() * mask.getWidth(); i++) {
            float backgroundLikelihood = 1 - mask.getBuffer().getFloat();
            if (backgroundLikelihood > 0.9) {
                colors[i] = argb(255, 255, 0, 255);
            } else if (backgroundLikelihood > 0.2) {
                // Linear interpolation to make sure when backgroundLikelihood is 0.2, the alpha is 0 and
                // when backgroundLikelihood is 0.9, the alpha is 128.
                // +0.5 to round the float value to the nearest int.
                double d = 182.9 * backgroundLikelihood - 36.6 + 0.5;
                int alpha = (int) d;
                colors[i] = argb(alpha, 255, 0, 255);
            }
        }
        return colors;
    }
}
