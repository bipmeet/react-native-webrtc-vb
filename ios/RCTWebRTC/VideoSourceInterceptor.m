//
//  VideoSourceInterceptor.m
//  react-native-webrtc
//
//  Created by YAVUZ SELIM CAKIR on 18.06.2022.
//

#import "VideoSourceInterceptor.h"
#import <WebRTC/RTCCVPixelBuffer.h>
#import <WebRTC/RTCVideoFrame.h>
#import <WebRTC/RTCNativeI420Buffer.h>
#import <WebRTC/RTCVideoFrameBuffer.h>

#import <MLKitSegmentationSelfie/MLKitSegmentationSelfie.h>
#import <MLKitSegmentationCommon/MLKSegmenter.h>
#import <MLKitSegmentationCommon/MLKSegmentationMask.h>
#import <MLKitVision/MLKVisionImage.h>

NS_ASSUME_NONNULL_BEGIN

@interface VideoSourceInterceptor ()

@property (nonatomic) RTCVideoCapturer *capturer;
@property (nonatomic, strong) MLKSegmenter *segmenter;
@property (nonatomic) RTCVideoRotation rotation;
@property (nonatomic) int64_t timeStampNs;
@property (nonatomic) CVPixelBufferRef backgroundBuffer;
@property (nonatomic) CVPixelBufferRef rightRotatedBackgroundBuffer;
@property (nonatomic) CVPixelBufferRef leftRotatedBackgroundBuffer;
@property (nonatomic) CVPixelBufferRef upsideRotatedBackgroundBuffer;

@property (nonatomic) UIImage *backgroundImage;
@property (nonatomic) UIImage *rightRotatedBackgroundImage;
@property (nonatomic) UIImage *leftRotatedBackgroundImage;
@property (nonatomic) UIImage *upsideDownBackgroundImage;

@end

@implementation VideoSourceInterceptor

- (instancetype)initWithVideoSource: (RTCVideoSource*) videoSource {
    if (self = [super init]) {
        _videoSource = videoSource;
        
        MLKSelfieSegmenterOptions *options = [[MLKSelfieSegmenterOptions alloc] init];
        options.segmenterMode = MLKSegmenterModeStream;
        options.shouldEnableRawSizeMask = NO;
        
        self.segmenter = [MLKSegmenter segmenterWithOptions:options];
        
        _backgroundImage = [UIImage imageNamed:@"portraitBackground"];
        _rightRotatedBackgroundImage = [UIImage imageNamed:@"rightRotatedBackground"];
        _leftRotatedBackgroundImage = [UIImage imageNamed:@"leftRotatedBackground"];
        _upsideDownBackgroundImage = [UIImage imageNamed:@"upsideDownBackground"];
        
        _backgroundBuffer = [self pixelBufferFromCGImage:_backgroundImage.CGImage];
        _rightRotatedBackgroundBuffer = [self pixelBufferFromCGImage:_rightRotatedBackgroundImage.CGImage];
        _leftRotatedBackgroundBuffer = [self pixelBufferFromCGImage:_leftRotatedBackgroundImage.CGImage];
        _upsideRotatedBackgroundBuffer = [self pixelBufferFromCGImage:_upsideDownBackgroundImage.CGImage];
    }
    return self;
}

- (CVPixelBufferRef) pixelBufferFromCGImage: (CGImageRef) image
{
    NSDictionary *options = @{
                              (NSString*)kCVPixelBufferCGImageCompatibilityKey : @YES,
                              (NSString*)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
                              };

    CVPixelBufferRef pxbuffer = NULL;
    
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, CGImageGetWidth(image),
                        CGImageGetHeight(image), kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef) options,
                        &pxbuffer);

    NSParameterAssert(status == kCVReturnSuccess && pxbuffer != NULL);

    CVPixelBufferLockBaseAddress(pxbuffer, 0);
    void *pxdata = CVPixelBufferGetBaseAddress(pxbuffer);

    CGColorSpaceRef rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pxdata, CGImageGetWidth(image),
                                                 CGImageGetHeight(image), 8, 4*CGImageGetWidth(image), rgbColorSpace,
                                                 kCGImageAlphaPremultipliedLast);
    NSParameterAssert(context);
    
    CGContextConcatCTM(context, CGAffineTransformMakeRotation(-90 * M_PI / 180.0));
    CGContextTranslateCTM(context, -640, 0);
    CGAffineTransform flipVertical = CGAffineTransformMake( 1, 0, 0, -1, 0, CGImageGetHeight(image) );
    CGContextConcatCTM(context, flipVertical);

    CGContextDrawImage(context, CGRectMake(0, 0, CGImageGetWidth(image),
                                           CGImageGetHeight(image)), image);
    CGColorSpaceRelease(rgbColorSpace);
    CGContextRelease(context);

    CVPixelBufferUnlockBaseAddress(pxbuffer, 0);
    return pxbuffer;
}

- (void)capturer:(nonnull RTCVideoCapturer *)capturer didCaptureVideoFrame:(nonnull RTCVideoFrame *)frame {
    
    RTCCVPixelBuffer* pixelBufferr = (RTCCVPixelBuffer *)frame.buffer;
    CVPixelBufferRef pixelBufferRef = pixelBufferr.pixelBuffer;

    self.rotation = frame.rotation;
    self.timeStampNs = frame.timeStampNs;
    self.capturer = capturer;
    
    CMSampleBufferRef sampleBuffer = [self getCMSampleBuffer:pixelBufferRef timeStamp:self.timeStampNs];
    
    MLKVisionImage *image = [[MLKVisionImage alloc] initWithBuffer:sampleBuffer];
    image.orientation = [self imageOrientation];
    
    NSError *error;
    MLKSegmentationMask *mask =
        [self.segmenter resultsInImage:image error:&error];
    if (error != nil) {
      // Error.
      return;
    }
    
    [self applySegmentationMask:mask
                  toPixelBuffer:pixelBufferRef
                       rotation:self.rotation];
    
    RTC_OBJC_TYPE(RTCCVPixelBuffer) *rtcPixelBuffer =
          [[RTC_OBJC_TYPE(RTCCVPixelBuffer) alloc] initWithPixelBuffer:pixelBufferRef];
    
    RTCI420Buffer *i420buffer = [rtcPixelBuffer toI420];
    
    RTC_OBJC_TYPE(RTCVideoFrame) *processedFrame =
          [[RTC_OBJC_TYPE(RTCVideoFrame) alloc] initWithBuffer:i420buffer
                                                      rotation:self.rotation
                                                   timeStampNs:self.timeStampNs];
    
    [_videoSource capturer:self.capturer didCaptureVideoFrame:processedFrame];
    
    CMSampleBufferInvalidate(sampleBuffer);
    CFRelease(sampleBuffer);
    sampleBuffer = NULL;
}

- (CMSampleBufferRef)getCMSampleBuffer: (CVPixelBufferRef)pixelBuffer timeStamp: (int64_t) timeStampNs  {

    CMSampleTimingInfo info = kCMTimingInfoInvalid;
    info.presentationTimeStamp = CMTimeMake(timeStampNs, 1000000000);;
    info.duration = kCMTimeInvalid;
    info.decodeTimeStamp = kCMTimeInvalid;

    CMFormatDescriptionRef formatDesc = nil;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDesc);

    CMSampleBufferRef sampleBuffer = nil;

    CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                             pixelBuffer,
                                             formatDesc,
                                             &info,
                                             &sampleBuffer);

    return sampleBuffer;
}

- (UIImageOrientation)imageOrientation {
  return [self imageOrientationFromDevicePosition:AVCaptureDevicePositionFront];
}

- (UIImageOrientation)imageOrientationFromDevicePosition:(AVCaptureDevicePosition)devicePosition {
    
    UIDeviceOrientation deviceOrientation = UIDevice.currentDevice.orientation;
    
    if (deviceOrientation == UIDeviceOrientationFaceDown ||
      deviceOrientation == UIDeviceOrientationFaceUp ||
      deviceOrientation == UIDeviceOrientationUnknown) {
        deviceOrientation = [self currentUIOrientation];
    }
    
    switch (deviceOrientation) {
        case UIDeviceOrientationPortrait:
            return devicePosition == AVCaptureDevicePositionFront ? UIImageOrientationLeftMirrored
                                                            : UIImageOrientationRight;
        case UIDeviceOrientationLandscapeLeft:
            return devicePosition == AVCaptureDevicePositionFront ? UIImageOrientationDownMirrored
                                                            : UIImageOrientationUp;
        case UIDeviceOrientationPortraitUpsideDown:
            return devicePosition == AVCaptureDevicePositionFront ? UIImageOrientationRightMirrored
                                                            : UIImageOrientationLeft;
        case UIDeviceOrientationLandscapeRight:
            return devicePosition == AVCaptureDevicePositionFront ? UIImageOrientationUpMirrored
                                                            : UIImageOrientationDown;
        case UIDeviceOrientationFaceDown:
        case UIDeviceOrientationFaceUp:
        case UIDeviceOrientationUnknown:
            return UIImageOrientationUp;
    }
}

- (UIDeviceOrientation)currentUIOrientation {
  UIDeviceOrientation (^deviceOrientation)(void) = ^UIDeviceOrientation(void) {
      switch (UIApplication.sharedApplication.statusBarOrientation) {
          case UIInterfaceOrientationLandscapeLeft:
              return UIDeviceOrientationLandscapeRight;
          case UIInterfaceOrientationLandscapeRight:
              return UIDeviceOrientationLandscapeLeft;
          case UIInterfaceOrientationPortraitUpsideDown:
              return UIDeviceOrientationPortraitUpsideDown;
          case UIInterfaceOrientationPortrait:
          case UIInterfaceOrientationUnknown:
              return UIDeviceOrientationPortrait;
      }
  };

  if (NSThread.isMainThread) {
      return deviceOrientation();
  } else {
      __block UIDeviceOrientation currentOrientation = UIDeviceOrientationPortrait;
      dispatch_sync(dispatch_get_main_queue(), ^{
      currentOrientation = deviceOrientation();
      });
    return currentOrientation;
  }
}

- (void)applySegmentationMask:(MLKSegmentationMask *)mask
                toPixelBuffer:(CVPixelBufferRef)imageBuffer
                     rotation:(RTCVideoRotation)rotation{
    
    CVPixelBufferRef currentBackground = NULL;
    
    switch (rotation) {
        case RTCVideoRotation_90:
            currentBackground = _backgroundBuffer;
            break;
        case RTCVideoRotation_0: //Right rotated screen
            currentBackground = _leftRotatedBackgroundBuffer;
            break;
        case RTCVideoRotation_270: //Upside down screen
            currentBackground = _upsideRotatedBackgroundBuffer;
            break;
        case RTCVideoRotation_180: //Left rotated screen
            currentBackground = _rightRotatedBackgroundBuffer;
            break;
    }
    
    size_t width = CVPixelBufferGetWidth(mask.buffer);
    size_t height = CVPixelBufferGetHeight(mask.buffer);

    CVPixelBufferLockBaseAddress(imageBuffer, 0);
    CVPixelBufferLockBaseAddress(currentBackground, 0);
    CVPixelBufferLockBaseAddress(mask.buffer, kCVPixelBufferLock_ReadOnly);

    float *maskAddress = (float *)CVPixelBufferGetBaseAddress(mask.buffer);
    size_t maskBytesPerRow = CVPixelBufferGetBytesPerRow(mask.buffer);

    unsigned char *imageAddress = (unsigned char *)CVPixelBufferGetBaseAddress(imageBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
    static const int kBGRABytesPerPixel = 4;
    
    unsigned char *backgroundImageAddress = (unsigned char *)CVPixelBufferGetBaseAddress(currentBackground);
    size_t backgroundImageBytesPerRow = CVPixelBufferGetBytesPerRow(currentBackground);
     
    static const float kMaxColorComponentValue = 255.0f;

    for (int row = 0; row < height; ++row) {
        for (int col = 0; col < width; ++col) {
            int pixelOffset = col * kBGRABytesPerPixel;
            int blueOffset = pixelOffset;
            int greenOffset = pixelOffset + 1;
            int redOffset = pixelOffset + 2;
            int alphaOffset = pixelOffset + 3;

            float maskValue = maskAddress[col];
            float backgroundRegionRatio = 1.0f - maskValue;

            float originalPixelRed = imageAddress[redOffset] / kMaxColorComponentValue;
            float originalPixelGreen = imageAddress[greenOffset] / kMaxColorComponentValue;
            float originalPixelBlue = imageAddress[blueOffset] / kMaxColorComponentValue;
            float originalPixelAlpha = imageAddress[alphaOffset] / kMaxColorComponentValue;
        
            float redOverlay = backgroundImageAddress[blueOffset] / kMaxColorComponentValue;
            float greenOverlay = backgroundImageAddress[greenOffset] / kMaxColorComponentValue;
            float blueOverlay = backgroundImageAddress[redOffset] / kMaxColorComponentValue;
            float alphaOverlay = backgroundRegionRatio;

            // Calculate composite color component values.
            // Derived from https://en.wikipedia.org/wiki/Alpha_compositing#Alpha_blending
            float compositeAlpha = ((1.0f - alphaOverlay) * originalPixelAlpha) + alphaOverlay;
            float compositeRed = 0.0f;
            float compositeGreen = 0.0f;
            float compositeBlue = 0.0f;
            // Only perform rgb blending calculations if the output alpha is > 0. A zero-value alpha
            // means none of the color channels actually matter, and would introduce division by 0.
            if (fabs(compositeAlpha) > FLT_EPSILON) {
                compositeRed = (((1.0f - alphaOverlay) * originalPixelAlpha * originalPixelRed) +
                        (alphaOverlay * redOverlay)) /
                       compositeAlpha;
                compositeGreen = (((1.0f - alphaOverlay) * originalPixelAlpha * originalPixelGreen) +
                          (alphaOverlay * greenOverlay)) /
                         compositeAlpha;
                compositeBlue = (((1.0f - alphaOverlay) * originalPixelAlpha * originalPixelBlue) +
                         (alphaOverlay * blueOverlay)) /
                        compositeAlpha;
            }

            imageAddress[blueOffset] = compositeBlue * kMaxColorComponentValue;
            imageAddress[greenOffset] = compositeGreen * kMaxColorComponentValue;
            imageAddress[redOffset] = compositeRed * kMaxColorComponentValue;
            imageAddress[alphaOffset] = compositeAlpha * kMaxColorComponentValue;
        }
        imageAddress += bytesPerRow / sizeof(unsigned char);
        backgroundImageAddress += backgroundImageBytesPerRow / sizeof(unsigned char);
        maskAddress += maskBytesPerRow / sizeof(float);
    }

    CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
    CVPixelBufferUnlockBaseAddress(currentBackground, 0);
    CVPixelBufferUnlockBaseAddress(mask.buffer, kCVPixelBufferLock_ReadOnly);
}

@end

NS_ASSUME_NONNULL_END
