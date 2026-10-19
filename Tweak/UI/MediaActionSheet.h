#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface YTKACEMediaAction : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy, nullable) NSString *detail;
@property(nonatomic, copy, nullable) NSString *symbol;
@property(nonatomic, copy) NSArray<YTKACEMediaAction *> *children;
@property(nonatomic, strong, nullable) UIView *customView;
@property(nonatomic, assign) BOOL enabled;
@property(nonatomic, assign) BOOL selected;
@property(nonatomic, assign) BOOL dismissesSheet;
@property(nonatomic, copy, nullable) dispatch_block_t handler;
+ (instancetype)action:(NSString *)identifier title:(NSString *)title
                symbol:(nullable NSString *)symbol handler:(nullable dispatch_block_t)handler;
+ (instancetype)group:(NSString *)identifier title:(NSString *)title
               symbol:(nullable NSString *)symbol children:(NSArray<YTKACEMediaAction *> *)children;
@end

@interface YTKACEMediaActionSheet : UIViewController
@property(nonatomic, copy) NSString *heading;
@property(nonatomic, copy) NSArray<NSArray<YTKACEMediaAction *> *> *actionSections;
- (void)setExpanded:(BOOL)expanded forAction:(NSString *)identifier;
- (void)reloadActions;
@end

NS_ASSUME_NONNULL_END
