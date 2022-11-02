package com.oney.WebRTCModule;

import android.graphics.Bitmap;
import android.graphics.Matrix;

import org.webrtc.VideoFrame;

import java.nio.ByteBuffer;

public class YuvFrame {
    public int width;
    public int height;
    public byte[] nv21Buffer;
    public int rotationDegree;
    public long timestamp;

    private final Object planeLock = new Object();

    public YuvFrame(final VideoFrame videoFrame) {
        fromVideoFrame(videoFrame, System.nanoTime());
    }

    public void fromVideoFrame(final VideoFrame videoFrame, final long timestamp) {
        if (videoFrame == null) {
            return;
        }

        synchronized (planeLock) {
            try {
                // Save timestamp
                this.timestamp = timestamp;

                // Copy rotation information
                rotationDegree = videoFrame.getRotation();  // Just save rotation info for now, doing actual rotation can wait until per-pixel processing.

                // Copy the pixel data, processing as requested.
                copyPlanes(videoFrame.getBuffer());
            } catch (Throwable t) {
                dispose();
            }
        }
    }

    public void dispose() {
        nv21Buffer = null;
    }

    private void copyPlanes( final VideoFrame.Buffer videoFrameBuffer )
    {
        VideoFrame.I420Buffer i420Buffer = null;

        if ( videoFrameBuffer != null )
        {
            i420Buffer = videoFrameBuffer.toI420();
        }

        if ( i420Buffer == null )
        {
            return;
        }

        synchronized ( planeLock )
        {
            // Set the width and height of the frame.
            width = i420Buffer.getWidth();
            height = i420Buffer.getHeight();

            // Calculate sizes needed to convert to NV21 buffer format
            final int size = width * height;
            final int chromaStride = width;
            final int chromaWidth = ( width + 1 ) / 2;
            final int chromaHeight = ( height + 1 ) / 2;
            final int nv21Size = size + chromaStride * chromaHeight;

            if ( nv21Buffer == null || nv21Buffer.length != nv21Size )
            {
                nv21Buffer = new byte[nv21Size];
            }

            final ByteBuffer yPlane = i420Buffer.getDataY();
            final ByteBuffer uPlane = i420Buffer.getDataU();
            final ByteBuffer vPlane = i420Buffer.getDataV();
            final int yStride = i420Buffer.getStrideY();
            final int uStride = i420Buffer.getStrideU();
            final int vStride = i420Buffer.getStrideV();

            // Populate a buffer in NV21 format because that's what the converter wants
            for ( int y = 0; y < height; y++ )
            {
                for ( int x = 0; x < width; x++ )
                {
                    nv21Buffer[y * width + x] = yPlane.get( y * yStride + x );
                }
            }

            for ( int y = 0; y < chromaHeight; y++ )
            {
                for ( int x = 0; x < chromaWidth; x++ )
                {
                    // Swapping U and V values here because it makes the image the right color

                    // Store V
                    nv21Buffer[size + y * chromaStride + 2 * x + 1] = uPlane.get( y * uStride + x );

                    // Store U
                    nv21Buffer[size + y * chromaStride + 2 * x] = vPlane.get( y * vStride + x );
                }
            }
        }
        i420Buffer.release();
    }

    public Bitmap getBitmap()
    {
        if ( nv21Buffer == null )
        {
            return null;
        }

        // Calculate the size of the frame
        final int size = width * height;

        // Allocate an array to hold the ARGB pixel data
        int[] argb = new int[size];

        // Use the converter (based on WebRTC source) to change to ARGB format
        YUV_NV21_TO_RGB(argb, nv21Buffer, width, height);

        // Construct a Bitmap based on the new pixel data
        Bitmap bitmap = Bitmap.createBitmap( argb, width, height, Bitmap.Config.ARGB_8888 );
        argb = null;

        // If necessary, generate a rotated version of the Bitmap
        if ( rotationDegree == 90 || rotationDegree == -270 )
        {
            final Matrix m = new Matrix();
            m.preScale(-1, 1);
            m.postRotate( 90 );

            return Bitmap.createBitmap( bitmap, 0, 0, bitmap.getWidth(), bitmap.getHeight(), m, true );
        }
        else if ( rotationDegree == 180 || rotationDegree == -180 )
        {
            final Matrix m = new Matrix();
            m.preScale(-1, 1);
            m.postRotate( 180 );

            return Bitmap.createBitmap( bitmap, 0, 0, bitmap.getWidth(), bitmap.getHeight(), m, true );
        }
        else if ( rotationDegree == 270 || rotationDegree == -90 )
        {
            final Matrix m = new Matrix();
            m.preScale(1, -1);
            m.postRotate( 270 );

            return Bitmap.createBitmap( bitmap, 0, 0, bitmap.getWidth(), bitmap.getHeight(), m, true );
        }
        else
        {
            final Matrix m = new Matrix();
            m.preScale(-1, 1);

            return Bitmap.createBitmap( bitmap, 0, 0, bitmap.getWidth(), bitmap.getHeight(), m, true );
        }
    }

    public static void YUV_NV21_TO_RGB(int[] argb, byte[] yuv, int width, int height) {
        final int frameSize = width * height;

        final int ii = 0;
        final int ij = 0;
        final int di = +1;
        final int dj = +1;

        int a = 0;
        for (int i = 0, ci = ii; i < height; ++i, ci += di) {
            for (int j = 0, cj = ij; j < width; ++j, cj += dj) {
                int y = (0xff & ((int) yuv[ci * width + cj]));
                int v = (0xff & ((int) yuv[frameSize + (ci >> 1) * width + (cj & ~1) + 0]));
                int u = (0xff & ((int) yuv[frameSize + (ci >> 1) * width + (cj & ~1) + 1]));
                y = y < 16 ? 16 : y;

                int r = (int) (1.164f * (y - 16) + 1.596f * (v - 128));
                int g = (int) (1.164f * (y - 16) - 0.813f * (v - 128) - 0.391f * (u - 128));
                int b = (int) (1.164f * (y - 16) + 2.018f * (u - 128));

                r = r < 0 ? 0 : (r > 255 ? 255 : r);
                g = g < 0 ? 0 : (g > 255 ? 255 : g);
                b = b < 0 ? 0 : (b > 255 ? 255 : b);

                argb[a++] = 0xff000000 | (r << 16) | (g << 8) | b;
            }
        }
    }
}

