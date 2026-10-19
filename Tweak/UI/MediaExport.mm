#import "MediaExport.h"
#import "Notice.h"
#import "../Runtime/Localization.h"
#import <Photos/Photos.h>

UIViewController *YTKACEMediaPresenter(UIView *sourceView) {
    UIWindow *window = sourceView.window;
    if (!window) for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive || ![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) if (candidate.isKeyWindow) { window = candidate; break; }
    }
    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController) controller = controller.presentedViewController;
    return controller;
}

static NSError *YTKACEImageError(NSString *message) {
    return [NSError errorWithDomain:@"YTKACEImages" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

void YTKACELoadImage(NSURL *URL, NSURL *fallbackURL, void (^completion)(NSData *, NSError *)) {
    if (!URL || ![@[@"http", @"https"] containsObject:URL.scheme.lowercaseString]) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, YTKACEImageError(YTKACELocalized(@"The image could not be loaded."))); });
        return;
    }
    [[NSURLSession.sharedSession dataTaskWithURL:URL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        BOOL valid = !error && status >= 200 && status < 300 && data.length > 0 && data.length <= 32 * 1024 * 1024 && [UIImage imageWithData:data] != nil;
        if (!valid && fallbackURL && ![fallbackURL isEqual:URL]) {
            YTKACELoadImage(fallbackURL, nil, completion);
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(valid ? data : nil, valid ? nil : (error ?: YTKACEImageError(YTKACELocalized(@"The image could not be loaded."))));
        });
    }] resume];
}

void YTKACESavePhotoData(NSArray<NSData *> *images, void (^completion)(BOOL, NSError *)) {
    if (!images.count) { completion(NO, YTKACEImageError(YTKACELocalized(@"No images found"))); return; }
    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status) {
        if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, YTKACEImageError(YTKACELocalized(@"YouTube needs permission to add to Photos."))); });
            return;
        }
        [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
            for (NSData *data in images) {
                PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
                [request addResourceWithType:PHAssetResourceTypePhoto data:data options:nil];
            }
        } completionHandler:^(BOOL success, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(success, error); });
        }];
    }];
}

@interface YTKACEMediaImageViewer : UIViewController <UIScrollViewDelegate>
@property(nonatomic, strong) UIImage *image;
@property(nonatomic, strong) UIImageView *imageView;
@end
@implementation YTKACEMediaImageViewer
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 5; scroll.delegate = self;
    self.imageView = [[UIImageView alloc] initWithImage:self.image];
    self.imageView.frame = scroll.bounds;
    self.imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [scroll addSubview:self.imageView]; [self.view addSubview:scroll];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
}
- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView { (void)scrollView; return self.imageView; }
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

void YTKACEPreviewImage(NSData *data, UIViewController *presenter) {
    UIImage *image = [UIImage imageWithData:data];
    if (!image || !presenter) return;
    YTKACEMediaImageViewer *viewer = [YTKACEMediaImageViewer new];
    viewer.image = image;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:viewer];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    [presenter presentViewController:navigation animated:YES completion:nil];
}

void YTKACEShareTextFile(NSString *text, NSString *filename, UIViewController *presenter, UIView *sourceView) {
    if (!presenter || !text.length) return;
    NSURL *directory = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    NSError *error = nil;
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error];
    NSURL *URL = [directory URLByAppendingPathComponent:filename.lastPathComponent];
    if (error || ![text writeToURL:URL atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        YTKACEShowNotice(error.localizedDescription ?: YTKACELocalized(@"Save failed")); return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[URL] applicationActivities:nil];
    share.popoverPresentationController.sourceView = sourceView ?: presenter.view;
    share.popoverPresentationController.sourceRect = (sourceView ?: presenter.view).bounds;
    share.completionWithItemsHandler = ^(__unused UIActivityType type, __unused BOOL completed, __unused NSArray *items, __unused NSError *shareError) {
        [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
    };
    [presenter presentViewController:share animated:YES completion:nil];
}
