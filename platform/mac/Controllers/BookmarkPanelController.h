#import <Cocoa/Cocoa.h>

@class AppDelegate;

// 书签面板控制器 - 负责书签面板UI的创建、布局和交互
@interface BookmarkPanelController : NSObject

@property(nonatomic, weak) AppDelegate* appDelegate;
@property(nonatomic, strong) NSView* bookmarkControlBar;
@property(nonatomic, strong) NSButton* bookmarkToggleButton;
@property(nonatomic, strong) NSView* leftPanel;
@property(nonatomic, assign) BOOL bookmarkVisible;
@property(nonatomic, strong) NSView* expandedTopControlBar;
@property(nonatomic, strong) NSOutlineView* outline;
@property(nonatomic, strong) NSScrollView* outlineScroll;

- (void)createBookmarkControlBar;
- (void)toggleBookmarkVisibility:(id)sender;
- (void)setBookmarkVisible:(BOOL)visible animated:(BOOL)animated;
- (void)expandAllBookmarks:(id)sender;
- (void)collapseAllBookmarks:(id)sender;
- (void)createExpandedBookmarkControls;
- (void)removeExpandedBookmarkControls;
- (void)updateBookmarkScrollView;
- (void)ensureBookmarkScrollBarVisible;
- (void)forceTraditionalScrollBar;
- (void)checkScrollBarOverlap;
- (void)ensureLeftPanelSize;
- (void)updateExpandedControlBarLayout;

@end

