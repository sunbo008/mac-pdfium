#import "BookmarkDelegate.h"
#import "../Models/TocNode.h"
#import "../Views/PdfView.h"
#include "public/fpdf_doc.h"

// 前向声明AppDelegate，避免循环依赖
@interface AppDelegate : NSObject
@property(nonatomic, strong) PdfView* view;
@end

@implementation BookmarkDelegate

- (void)rebuildToc {
  FPDF_DOCUMENT doc = [self.appDelegate.view document];
  if (!doc) {
    self.tocRoot = nil;
    [self.outline reloadData];
    return;
  }
  self.tocRoot = BuildBookmarksTree(doc);
  [self.outline reloadData];
  // 默认折叠所有顶层书签
  [self.outline collapseItem:nil collapseChildren:YES];
  NSLog(@"[BookmarkControl] 书签重建完成，默认折叠所有顶层书签");

  // 确保滚动条正确更新
  [self updateBookmarkScrollView];
  // Note: ensureBookmarkScrollBarVisible应该由BookmarkPanelController调用
}

- (void)updateBookmarkScrollView {
  NSLog(@"[ScrollDebug] ========== updateBookmarkScrollView 开始 ==========");

  // 强制更新滚动视图的内容大小和滚动条
  if (self.outlineScroll && !self.outlineScroll.hidden) {
    NSLog(@"[ScrollDebug] 滚动视图存在且未隐藏");

    // 打印滚动视图基本信息
    NSLog(@"[ScrollDebug] outlineScroll frame: %@",
          NSStringFromRect(self.outlineScroll.frame));
    NSLog(@"[ScrollDebug] outlineScroll bounds: %@",
          NSStringFromRect(self.outlineScroll.bounds));
    NSLog(@"[ScrollDebug] outlineScroll superview: %@",
          self.outlineScroll.superview);
    NSLog(@"[ScrollDebug] outlineScroll hidden: %@",
          self.outlineScroll.hidden ? @"YES" : @"NO");
    NSLog(@"[ScrollDebug] outlineScroll alphaValue: %.2f",
          self.outlineScroll.alphaValue);

    // 确保outline view布局正确
    [self.outline setNeedsLayout:YES];
    [self.outline layoutSubtreeIfNeeded];

    // 打印outline view信息
    NSLog(@"[ScrollDebug] outline frame: %@",
          NSStringFromRect(self.outline.frame));
    NSLog(@"[ScrollDebug] outline bounds: %@",
          NSStringFromRect(self.outline.bounds));
    NSLog(@"[ScrollDebug] outline numberOfRows: %ld",
          (long)[self.outline numberOfRows]);
    NSLog(@"[ScrollDebug] outline rowHeight: %.1f", [self.outline rowHeight]);

    // 更新滚动视图内容大小
    [self.outlineScroll.documentView setNeedsLayout:YES];
    [self.outlineScroll reflectScrolledClipView:self.outlineScroll.contentView];

    // 打印内容视图信息
    NSView* contentView = self.outlineScroll.contentView;
    NSLog(@"[ScrollDebug] contentView frame: %@",
          NSStringFromRect(contentView.frame));
    NSLog(@"[ScrollDebug] contentView bounds: %@",
          NSStringFromRect(contentView.bounds));
    NSLog(@"[ScrollDebug] documentView frame: %@",
          NSStringFromRect(self.outlineScroll.documentView.frame));

    // 强制重新计算滚动条
    [self.outlineScroll setNeedsDisplay:YES];

    // 详细检查滚动条状态
    NSLog(@"[ScrollDebug] hasVerticalScroller: %@",
          self.outlineScroll.hasVerticalScroller ? @"YES" : @"NO");
    NSLog(@"[ScrollDebug] hasHorizontalScroller: %@",
          self.outlineScroll.hasHorizontalScroller ? @"YES" : @"NO");
    NSLog(@"[ScrollDebug] autohidesScrollers: %@",
          self.outlineScroll.autohidesScrollers ? @"YES" : @"NO");
    NSLog(@"[ScrollDebug] scrollerStyle: %ld",
          (long)self.outlineScroll.scrollerStyle);
    NSLog(@"[ScrollDebug] borderType: %ld",
          (long)self.outlineScroll.borderType);

    // 确保滚动条可见性正确
    if (self.outlineScroll.hasVerticalScroller) {
      NSScroller* vScroller = self.outlineScroll.verticalScroller;
      if (vScroller) {
        NSLog(@"[ScrollDebug] verticalScroller 存在");
        NSLog(@"[ScrollDebug] verticalScroller frame: %@",
              NSStringFromRect(vScroller.frame));
        NSLog(@"[ScrollDebug] verticalScroller bounds: %@",
              NSStringFromRect(vScroller.bounds));
        NSLog(@"[ScrollDebug] verticalScroller hidden: %@",
              vScroller.hidden ? @"YES" : @"NO");
        NSLog(@"[ScrollDebug] verticalScroller enabled: %@",
              vScroller.enabled ? @"YES" : @"NO");
        NSLog(@"[ScrollDebug] verticalScroller alphaValue: %.2f",
              vScroller.alphaValue);
        NSLog(@"[ScrollDebug] verticalScroller controlSize: %ld",
              (long)vScroller.controlSize);
        NSLog(@"[ScrollDebug] verticalScroller scrollerStyle: %ld",
              (long)vScroller.scrollerStyle);
        NSLog(@"[ScrollDebug] verticalScroller knobProportion: %.3f",
              vScroller.knobProportion);
        NSLog(@"[ScrollDebug] verticalScroller doubleValue: %.3f",
              vScroller.doubleValue);

        [vScroller setEnabled:YES];
        [vScroller setHidden:NO];
        [vScroller setNeedsDisplay:YES];

        NSLog(@"[ScrollDebug] 滚动条属性已强制设置");
      } else {
        NSLog(@"[ScrollDebug] ❌ verticalScroller 为 nil！");
      }
    } else {
      NSLog(@"[ScrollDebug] ❌ hasVerticalScroller 为 NO！");
    }

    NSLog(@"[BookmarkControl] 书签滚动视图已更新，滚动条状态已刷新");
  } else {
    if (!self.outlineScroll) {
      NSLog(@"[ScrollDebug] ❌ outlineScroll 为 nil！");
    } else if (self.outlineScroll.hidden) {
      NSLog(@"[ScrollDebug] ❌ outlineScroll 被隐藏！");
    }
  }

  NSLog(@"[ScrollDebug] ========== updateBookmarkScrollView 结束 ==========");
}

#pragma mark - NSOutlineViewDataSource

- (NSInteger)outlineView:(NSOutlineView*)outlineView
    numberOfChildrenOfItem:(id)item {
  TocNode* n = item ?: self.tocRoot;
  return n ? (NSInteger)n.children.count : 0;
}

- (id)outlineView:(NSOutlineView*)outlineView
            child:(NSInteger)index
           ofItem:(id)item {
  TocNode* n = item ?: self.tocRoot;
  return (index >= 0 && index < (NSInteger)n.children.count)
             ? n.children[(NSUInteger)index]
             : nil;
}

- (BOOL)outlineView:(NSOutlineView*)outlineView isItemExpandable:(id)item {
  TocNode* n = (TocNode*)item;
  return n.children.count > 0;
}

#pragma mark - NSOutlineViewDelegate

- (NSView*)outlineView:(NSOutlineView*)outlineView
    viewForTableColumn:(NSTableColumn*)tableColumn
                  item:(id)item {
  NSTableCellView* cell = [outlineView makeViewWithIdentifier:@"tocCell"
                                                        owner:self];
  if (!cell) {
    cell = [[NSTableCellView alloc]
        initWithFrame:NSMakeRect(0, 0, tableColumn.width, 20)];
    cell.identifier = @"tocCell";
    NSTextField* text = [[NSTextField alloc] initWithFrame:cell.bounds];
    text.bezeled = NO;
    text.drawsBackground = NO;
    text.editable = NO;
    text.selectable = NO;
    text.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    cell.textField = text;
    [cell addSubview:text];
  }
  TocNode* n = (TocNode*)item;
  cell.textField.stringValue = n.title ?: @"";
  return cell;
}

- (void)outlineView:(NSOutlineView*)outlineView
    didClickTableColumn:(NSTableColumn*)tableColumn {
  // 双击跳页（当前为空实现）
}

- (void)outlineViewSelectionDidChange:(NSNotification*)notification {
  NSInteger row = self.outline.selectedRow;
  if (row < 0) {
    return;
  }
  id item = [self.outline itemAtRow:row];
  TocNode* n = (TocNode*)item;
  if (n.pageIndex >= 0) {
    [self.appDelegate.view goToPage:n.pageIndex];
  }
}

#pragma mark - 书签高亮和导航

- (TocNode*)findBookmarkForPage:(int)pageIndex inNode:(TocNode*)node {
  if (!node) {
    return nil;
  }

  NSLog(@"[BookmarkSearch] 搜索页面 %d，检查节点: %@ (页面: %d)", pageIndex,
        node.title, node.pageIndex);

  // 检查当前节点是否精确匹配
  if (node.pageIndex == pageIndex) {
    NSLog(@"[BookmarkSearch] 找到精确匹配: %@", node.title);
    return node;
  }

  // 查找最接近的书签（页面索引小于等于当前页面的最大值）
  TocNode* bestMatch = nil;
  if (node.pageIndex >= 0 && node.pageIndex <= pageIndex) {
    bestMatch = node;
    NSLog(@"[BookmarkSearch] 当前最佳匹配: %@ (页面: %d)", bestMatch.title,
          bestMatch.pageIndex);
  }

  // 递归搜索子节点
  for (TocNode* child in node.children) {
    TocNode* childMatch = [self findBookmarkForPage:pageIndex inNode:child];
    if (childMatch) {
      // 如果找到精确匹配，直接返回
      if (childMatch.pageIndex == pageIndex) {
        NSLog(@"[BookmarkSearch] 子节点中找到精确匹配: %@", childMatch.title);
        return childMatch;
      }
      // 否则选择页面索引更接近的那个
      if (!bestMatch || childMatch.pageIndex > bestMatch.pageIndex) {
        bestMatch = childMatch;
        NSLog(@"[BookmarkSearch] 更新最佳匹配: %@ (页面: %d)", bestMatch.title,
              bestMatch.pageIndex);
      }
    }
  }

  return bestMatch;
}

- (void)highlightCurrentBookmark {
  if (!self.tocRoot || !self.appDelegate.view) {
    NSLog(@"[BookmarkHighlight] tocRoot或view为空，跳过高亮");
    return;
  }

  int currentPage = [self.appDelegate.view currentPageIndex];
  NSLog(@"[BookmarkHighlight] 当前页面: %d", currentPage);

  // 查找对应的书签
  TocNode* targetBookmark = [self findBookmarkForPage:currentPage
                                               inNode:self.tocRoot];
  if (targetBookmark) {
    NSLog(@"[BookmarkHighlight] 找到匹配书签: %@ (页面 %d)",
          targetBookmark.title, targetBookmark.pageIndex);

    // 确保书签的父节点都是展开的，这样才能看到目标书签
    [self expandParentsOfItem:targetBookmark];

    // 在outline view中选中该书签
    NSInteger row = [self.outline rowForItem:targetBookmark];
    if (row >= 0) {
      [self.outline selectRowIndexes:[NSIndexSet indexSetWithIndex:row]
                byExtendingSelection:NO];

      // 平滑滚动到选中的书签，确保其可见
      [NSAnimationContext
          runAnimationGroup:^(NSAnimationContext* context) {
            context.duration = 0.3;  // 平滑滚动动画
            context.allowsImplicitAnimation = YES;
            [self.outline.animator scrollRowToVisible:row];
          }
          completionHandler:^{
            // 滚动完成后确保滚动条状态正确
            [self updateBookmarkScrollView];
            // Note: ensureBookmarkScrollBarVisible应该由BookmarkPanelController调用
          }];

      NSLog(@"[BookmarkHighlight] 书签已高亮，行号: %ld", (long)row);
    } else {
      NSLog(@"[BookmarkHighlight] 无法找到书签对应的行，可能书签被折叠了");
    }
  } else {
    NSLog(@"[BookmarkHighlight] 未找到匹配的书签");
    // 清除选择
    [self.outline deselectAll:nil];
  }
}

- (void)expandParentsOfItem:(TocNode*)item {
  if (!item || !self.tocRoot) {
    return;
  }

  // 查找item的父节点路径
  NSMutableArray* parentPath = [NSMutableArray array];
  [self findParentPathForItem:item inNode:self.tocRoot parentPath:parentPath];

  // 展开所有父节点
  for (TocNode* parent in parentPath) {
    if (parent != self.tocRoot) {  // 不展开根节点
      [self.outline expandItem:parent];
      NSLog(@"[BookmarkHighlight] 展开父节点: %@", parent.title);
    }
  }
}

- (BOOL)findParentPathForItem:(TocNode*)targetItem
                       inNode:(TocNode*)currentNode
                   parentPath:(NSMutableArray*)path {
  if (!currentNode) {
    return NO;
  }

  // 将当前节点加入路径
  [path addObject:currentNode];

  // 检查是否找到目标项
  if (currentNode == targetItem) {
    return YES;
  }

  // 在子节点中搜索
  for (TocNode* child in currentNode.children) {
    if ([self findParentPathForItem:targetItem inNode:child parentPath:path]) {
      return YES;
    }
  }

  // 如果在这个分支中没找到，从路径中移除当前节点
  [path removeLastObject];
  return NO;
}

@end

