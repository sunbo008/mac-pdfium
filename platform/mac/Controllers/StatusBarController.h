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

- (void)createStatusBar;
- (void)updateStatusBar;
- (void)onPrevPage:(id)sender;
- (void)onNextPage:(id)sender;
- (void)onPageInputChanged:(id)sender;

@end

