#import <Cocoa/Cocoa.h>

@class AppDelegate;
@class PdfView;

// 状态栏控制器 - 负责状态栏UI和页面导航
@interface StatusBarController : NSObject

@property(nonatomic, weak) AppDelegate* appDelegate;
@property(nonatomic, weak) PdfView* pdfView;
@property(nonatomic, strong) NSView* statusBar;
@property(nonatomic, strong) NSTextField* pageLabel;
@property(nonatomic, strong) NSTextField* pageInput;
@property(nonatomic, strong) NSTextField* totalPagesLabel;
@property(nonatomic, strong) NSButton* prevPageButton;
@property(nonatomic, strong) NSButton* nextPageButton;

// 缩放控制相关属性
@property(nonatomic, strong) NSButton* zoomOutButton;
@property(nonatomic, strong) NSTextField* zoomInput;
@property(nonatomic, strong) NSButton* zoomInButton;

// 水印控制相关属性
@property(nonatomic, strong) NSButton* watermarkToggleButton;

// [AP-FORM-IMAGE-REPLACEMENT] 图片替换控制相关属性
@property(nonatomic, strong) NSButton* imageReplacementButton;

- (void)createStatusBar;
- (void)updateStatusBar;
- (void)onPrevPage:(id)sender;
- (void)onNextPage:(id)sender;
- (void)onPageInputChanged:(id)sender;

// 缩放控制方法
- (void)onZoomOut:(id)sender;
- (void)onZoomIn:(id)sender;
- (void)onZoomInputChanged:(id)sender;

// 水印控制方法
- (void)onWatermarkToggle:(id)sender;

// [AP-FORM-IMAGE-REPLACEMENT] 图片替换控制方法
- (void)onImageReplacement:(id)sender;

@end

