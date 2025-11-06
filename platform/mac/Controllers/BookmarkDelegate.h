#import <Cocoa/Cocoa.h>

@class AppDelegate;
@class TocNode;
@class PdfView;

// 书签委托 - 负责书签树的数据管理和交互
@interface BookmarkDelegate
    : NSObject <NSOutlineViewDataSource, NSOutlineViewDelegate>

@property(nonatomic, weak) AppDelegate* appDelegate;
@property(nonatomic, weak) PdfView* pdfView;
@property(nonatomic, strong) TocNode* tocRoot;
@property(nonatomic, strong) NSOutlineView* outline;
@property(nonatomic, strong) NSScrollView* outlineScroll;

- (void)rebuildToc;
- (void)updateBookmarkScrollView;
- (void)highlightCurrentBookmark;
- (TocNode*)findBookmarkForPage:(int)pageIndex inNode:(TocNode*)node;
- (void)expandParentsOfItem:(TocNode*)item;
- (BOOL)findParentPathForItem:(TocNode*)targetItem
                       inNode:(TocNode*)currentNode
                   parentPath:(NSMutableArray*)path;

@end
