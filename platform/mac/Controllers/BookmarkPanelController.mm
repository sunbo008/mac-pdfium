#import "BookmarkPanelController.h"

// 界面布局常量
static const CGFloat kBookmarkCollapsedWidth = 20.0;
static const CGFloat kBookmarkExpandedWidth = 260.0;
static const CGFloat kControlBarHeight = 30.0;

// 前向声明AppDelegate，避免循环依赖
@interface AppDelegate : NSObject
@property(nonatomic, strong) NSSplitView* split;
@property(nonatomic, strong) NSWindow* window;
- (void)highlightCurrentBookmark;
@end

@implementation BookmarkPanelController

- (void)createBookmarkControlBar {
  NSLog(@"[BookmarkControl] 开始创建书签控制栏");

  // 创建控制栏容器（只在收起状态下可见）
  self.bookmarkControlBar = [[NSView alloc]
      initWithFrame:NSMakeRect(0, 0, kBookmarkCollapsedWidth,
                               self.leftPanel.bounds.size.height)];
  self.bookmarkControlBar.wantsLayer = YES;
  self.bookmarkControlBar.layer.backgroundColor =
      [[NSColor controlBackgroundColor] CGColor];
  self.bookmarkControlBar.autoresizingMask =
      NSViewHeightSizable;  // 只允许高度自适应，宽度固定

  // 创建展开/收起按钮（垂直居中，水平居中）
  CGFloat buttonWidth = 16;
  CGFloat buttonHeight = 16;
  CGFloat xCenter =
      (self.bookmarkControlBar.bounds.size.width - buttonWidth) / 2;
  CGFloat yCenter =
      (self.bookmarkControlBar.bounds.size.height - buttonHeight) / 2;
  self.bookmarkToggleButton = [[NSButton alloc]
      initWithFrame:NSMakeRect(xCenter, yCenter, buttonWidth, buttonHeight)];
  self.bookmarkToggleButton.title =
      @"▶";  // 右箭头表示可以展开（收起状态下显示）
  self.bookmarkToggleButton.font = [NSFont systemFontOfSize:10];
  self.bookmarkToggleButton.bordered = NO;
  self.bookmarkToggleButton.target = self;
  self.bookmarkToggleButton.action = @selector(toggleBookmarkVisibility:);
  [self.bookmarkControlBar addSubview:self.bookmarkToggleButton];

  [self.leftPanel addSubview:self.bookmarkControlBar];

  NSLog(@"[BookmarkControl] 书签控制栏创建完成");
}

- (void)toggleBookmarkVisibility:(id)sender {
  NSLog(@"[BookmarkControl] 切换书签可见性，当前状态: %@",
        self.bookmarkVisible ? @"可见" : @"隐藏");
  [self setBookmarkVisible:!self.bookmarkVisible animated:YES];
}

- (void)setBookmarkVisible:(BOOL)visible animated:(BOOL)animated {
  if (self.bookmarkVisible == visible) {
    return;  // 状态未改变
  }

  self.bookmarkVisible = visible;
  NSLog(@"[BookmarkControl] 设置书签可见性: %@", visible ? @"显示" : @"隐藏");

  // 计算新的宽度 - 使用常量确保一致性
  CGFloat newWidth = visible ? kBookmarkExpandedWidth : kBookmarkCollapsedWidth;
  NSLog(@"[ScrollDebug] 准备调整左侧面板宽度从当前到: %.1f", newWidth);
  NSLog(@"[ScrollDebug] 当前左侧面板 frame: %@",
        NSStringFromRect(self.leftPanel.frame));

  if (animated) {
    // 如果要展开，先创建展开状态的控件并隐藏收起状态的控制栏
    if (visible) {
      [self createExpandedBookmarkControls];
      self.bookmarkControlBar.hidden = YES;  // 隐藏收起状态的控制栏
    } else {
      // 如果要收起，显示收起状态的控制栏
      self.bookmarkControlBar.hidden = NO;
    }

    [NSAnimationContext
        runAnimationGroup:^(NSAnimationContext* context) {
          context.duration = 0.25;  // 动画持续时间
          context.allowsImplicitAnimation = YES;

          // 调整左侧面板宽度 - 这是关键修复
          NSRect leftFrame = self.leftPanel.frame;
          leftFrame.size.width = newWidth;
          NSLog(@"[ScrollDebug] 动画中设置左侧面板 frame: %@",
                NSStringFromRect(leftFrame));
          self.leftPanel.animator.frame = leftFrame;

          // 调整分割视图位置
          [self.appDelegate.split.animator setPosition:newWidth
                                      ofDividerAtIndex:0];

          // 在动画过程中也更新控制栏布局
          if (visible && self.expandedTopControlBar) {
            [self updateExpandedControlBarLayout];
          }
        }
        completionHandler:^{
          // 动画完成后的处理
          NSLog(@"[ScrollDebug] 动画完成，最终左侧面板 frame: %@",
                NSStringFromRect(self.leftPanel.frame));

          if (!visible) {
            // 收起完成，移除展开状态的控件
            [self removeExpandedBookmarkControls];
            NSLog(@"[BookmarkControl] 收起完成，显示收起状态控制栏");
          } else {
            // 展开完成，确保控制栏布局正确
            [self updateExpandedControlBarLayout];
            NSLog(@"[BookmarkControl] 展开完成，隐藏收起状态控制栏");
          }
        }];
  } else {
    // 不使用动画，立即调整
    NSRect leftFrame = self.leftPanel.frame;
    leftFrame.size.width = newWidth;
    NSLog(@"[ScrollDebug] 立即设置左侧面板 frame: %@",
          NSStringFromRect(leftFrame));
    self.leftPanel.frame = leftFrame;

    [self.appDelegate.split setPosition:newWidth ofDividerAtIndex:0];

    if (visible) {
      [self createExpandedBookmarkControls];
      self.bookmarkControlBar.hidden = YES;  // 隐藏收起状态的控制栏
      // 立即更新控制栏布局
      [self updateExpandedControlBarLayout];
      NSLog(@"[BookmarkControl] 立即展开，隐藏收起状态控制栏");
    } else {
      [self removeExpandedBookmarkControls];
      self.bookmarkControlBar.hidden = NO;  // 显示收起状态的控制栏
      NSLog(@"[BookmarkControl] 立即收起，显示收起状态控制栏");
    }
  }
}

- (void)expandAllBookmarks:(id)sender {
  NSLog(@"[BookmarkControl] 展开所有书签");
  [self.outline expandItem:nil expandChildren:YES];

  // 延迟更新滚动条，确保展开动画完成
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [self updateBookmarkScrollView];
        [self ensureBookmarkScrollBarVisible];
      });
}

- (void)collapseAllBookmarks:(id)sender {
  NSLog(@"[BookmarkControl] 折叠所有书签");
  [self.outline collapseItem:nil collapseChildren:YES];

  // 延迟更新滚动条，确保折叠动画完成
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [self updateBookmarkScrollView];
        [self ensureBookmarkScrollBarVisible];
      });
}

- (void)createExpandedBookmarkControls {
  NSLog(@"[BookmarkControl] 创建展开状态的书签控件");

  // 完全隐藏收起状态的控制栏，确保不会阻挡事件
  self.bookmarkControlBar.hidden = YES;
  self.bookmarkControlBar.alphaValue = 0.0;       // 完全透明
  [self.bookmarkControlBar removeFromSuperview];  // 临时从视图层次中移除

  // 创建顶部控制栏（包含标题、+/-按钮）
  CGFloat expandedWidth = self.leftPanel.bounds.size.width;  // 使用实际面板宽度
  CGFloat controlBarY = self.leftPanel.bounds.size.height - kControlBarHeight;
  NSLog(@"[ScrollDebug] 创建expandedTopControlBar: width=%.1f, y=%.1f, "
        @"leftPanel.bounds=%@",
        expandedWidth, controlBarY, NSStringFromRect(self.leftPanel.bounds));

  self.expandedTopControlBar =
      [[NSView alloc] initWithFrame:NSMakeRect(0, controlBarY, expandedWidth,
                                               kControlBarHeight)];
  self.expandedTopControlBar.wantsLayer = YES;
  self.expandedTopControlBar.layer.backgroundColor =
      [[NSColor controlBackgroundColor] CGColor];

  // 设置自动调整掩码，确保状态栏跟随面板大小变化
  self.expandedTopControlBar.autoresizingMask =
      NSViewWidthSizable | NSViewMinYMargin;

  // 添加底部分隔线
  NSView* separator =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, expandedWidth, 1)];
  separator.wantsLayer = YES;
  separator.layer.backgroundColor = [[NSColor separatorColor] CGColor];
  separator.autoresizingMask = NSViewWidthSizable;  // 分隔线随宽度自动调整
  [self.expandedTopControlBar addSubview:separator];

  // 添加标题标签
  NSTextField* titleLabel =
      [[NSTextField alloc] initWithFrame:NSMakeRect(10, 6, 50, 18)];
  titleLabel.stringValue = @"书签";
  titleLabel.font = [NSFont systemFontOfSize:13];
  titleLabel.textColor = [NSColor labelColor];
  titleLabel.backgroundColor = [NSColor clearColor];
  titleLabel.bordered = NO;
  titleLabel.editable = NO;
  titleLabel.selectable = NO;
  [self.expandedTopControlBar addSubview:titleLabel];

  // 添加展开所有按钮（+）
  NSButton* expandAllButton =
      [[NSButton alloc] initWithFrame:NSMakeRect(70, 3, 24, 24)];
  expandAllButton.title = @"+";
  expandAllButton.font = [NSFont systemFontOfSize:14];
  expandAllButton.bordered = NO;
  expandAllButton.target = self;
  expandAllButton.action = @selector(expandAllBookmarks:);
  [self.expandedTopControlBar addSubview:expandAllButton];
  NSLog(@"[BookmarkControl] +按钮创建: frame=%@, superview=%@",
        NSStringFromRect(expandAllButton.frame), expandAllButton.superview);

  // 添加折叠所有按钮（-）
  NSButton* collapseAllButton =
      [[NSButton alloc] initWithFrame:NSMakeRect(100, 3, 24, 24)];
  collapseAllButton.title = @"−";
  collapseAllButton.font = [NSFont systemFontOfSize:14];
  collapseAllButton.bordered = NO;
  collapseAllButton.target = self;
  collapseAllButton.action = @selector(collapseAllBookmarks:);
  [self.expandedTopControlBar addSubview:collapseAllButton];
  NSLog(@"[BookmarkControl] -按钮创建: frame=%@, superview=%@",
        NSStringFromRect(collapseAllButton.frame), collapseAllButton.superview);

  // 添加展开状态的收起按钮（位于右侧边缘）
  CGFloat buttonWidth = 16;
  CGFloat buttonHeight = 16;
  CGFloat rightMargin = 4;
  CGFloat yCenter = (kControlBarHeight - buttonHeight) / 2;
  CGFloat buttonX = expandedWidth - buttonWidth - rightMargin;
  NSButton* collapseButton = [[NSButton alloc]
      initWithFrame:NSMakeRect(buttonX, yCenter, buttonWidth, buttonHeight)];
  collapseButton.title = @"◀";  // 左箭头表示可以收起
  collapseButton.font = [NSFont systemFontOfSize:10];
  collapseButton.bordered = NO;
  collapseButton.target = self;
  collapseButton.action = @selector(toggleBookmarkVisibility:);
  collapseButton.autoresizingMask = NSViewMinXMargin;  // 右对齐，随面板宽度调整
  [self.expandedTopControlBar addSubview:collapseButton];
  NSLog(
      @"[BookmarkControl] ◀按钮创建: frame=%@, expandedTopControlBar.bounds=%@",
      NSStringFromRect(collapseButton.frame),
      NSStringFromRect(self.expandedTopControlBar.bounds));

  [self.leftPanel addSubview:self.expandedTopControlBar];
  NSLog(@"[BookmarkControl] expandedTopControlBar创建: frame=%@, "
        @"leftPanel.bounds=%@",
        NSStringFromRect(self.expandedTopControlBar.frame),
        NSStringFromRect(self.leftPanel.bounds));

  // 显示书签列表
  NSLog(@"[ScrollDebug] 准备显示书签列表，设置 outlineScroll.hidden = NO");
  NSLog(@"[ScrollDebug] 显示前 outlineScroll frame: %@",
        NSStringFromRect(self.outlineScroll.frame));
  NSLog(@"[ScrollDebug] 显示前 leftPanel bounds: %@",
        NSStringFromRect(self.leftPanel.bounds));

  self.outlineScroll.hidden = NO;

  NSLog(@"[ScrollDebug] 显示后 outlineScroll hidden: %@",
        self.outlineScroll.hidden ? @"YES" : @"NO");

  // 立即检查滚动条状态
  dispatch_async(dispatch_get_main_queue(), ^{
    NSLog(@"[ScrollDebug] 异步检查滚动条状态...");

    // 首先确保左侧面板和滚动视图尺寸正确
    [self ensureLeftPanelSize];

    // 更新展开状态控制栏布局
    [self updateExpandedControlBarLayout];

    [self forceTraditionalScrollBar];  // 强制使用传统滚动条
    [self updateBookmarkScrollView];
    [self ensureBookmarkScrollBarVisible];
    [self checkScrollBarOverlap];  // 检查滚动条是否被遮挡
  });
}

- (void)removeExpandedBookmarkControls {
  NSLog(@"[BookmarkControl] 移除展开状态的书签控件");

  // 移除顶部控制栏
  if (self.expandedTopControlBar) {
    [self.expandedTopControlBar removeFromSuperview];
    self.expandedTopControlBar = nil;
  }

  // 恢复收起状态的控制栏
  [self.leftPanel addSubview:self.bookmarkControlBar];
  self.bookmarkControlBar.hidden = NO;
  self.bookmarkControlBar.alphaValue = 1.0;  // 恢复不透明

  // 隐藏书签列表
  self.outlineScroll.hidden = YES;
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

- (void)ensureBookmarkScrollBarVisible {
  NSLog(@"[ScrollDebug] ========== ensureBookmarkScrollBarVisible 开始 "
        @"==========");

  if (!self.outlineScroll || self.outlineScroll.hidden) {
    if (!self.outlineScroll) {
      NSLog(@"[ScrollDebug] ❌ outlineScroll 为 nil，退出");
    } else {
      NSLog(@"[ScrollDebug] ❌ outlineScroll 被隐藏，退出");
    }
    return;
  }

  NSLog(@"[ScrollDebug] 检查并确保滚动条可见性");

  // 获取outline view的内容高度
  NSInteger rowCount = [self.outline numberOfRows];
  CGFloat rowHeight = [self.outline rowHeight];
  CGFloat totalContentHeight = rowCount * rowHeight;
  CGFloat visibleHeight = self.outlineScroll.contentView.bounds.size.height;
  CGFloat scrollViewHeight = self.outlineScroll.bounds.size.height;

  NSLog(@"[ScrollDebug] 行数: %ld", (long)rowCount);
  NSLog(@"[ScrollDebug] 行高: %.1f", rowHeight);
  NSLog(@"[ScrollDebug] 总内容高度: %.1f", totalContentHeight);
  NSLog(@"[ScrollDebug] 可见高度(contentView): %.1f", visibleHeight);
  NSLog(@"[ScrollDebug] 滚动视图高度: %.1f", scrollViewHeight);

  // 如果内容高度超过可见高度，确保滚动条可见
  BOOL shouldShowScrollBar = (totalContentHeight > visibleHeight);
  NSLog(@"[ScrollDebug] 是否应该显示滚动条: %@",
        shouldShowScrollBar ? @"YES" : @"NO");

  if (shouldShowScrollBar) {
    NSLog(@"[ScrollDebug] 内容超出可见区域，强制显示滚动条");

    // 强制显示滚动条
    self.outlineScroll.hasVerticalScroller = YES;
    self.outlineScroll.autohidesScrollers = NO;

    NSLog(@"[ScrollDebug] 设置 hasVerticalScroller = YES, autohidesScrollers = "
          @"NO");

    NSScroller* vScroller = self.outlineScroll.verticalScroller;
    if (vScroller) {
      NSLog(@"[ScrollDebug] 找到 verticalScroller，开始配置");
      NSLog(@"[ScrollDebug] 配置前 - hidden: %@, enabled: %@",
            vScroller.hidden ? @"YES" : @"NO",
            vScroller.enabled ? @"YES" : @"NO");

      [vScroller setEnabled:YES];
      [vScroller setHidden:NO];
      [vScroller setNeedsDisplay:YES];

      // 设置滚动条样式和大小
      vScroller.controlSize = NSControlSizeRegular;
      if (@available(macOS 10.7, *)) {
        vScroller.scrollerStyle = NSScrollerStyleOverlay;
      }

      NSLog(@"[ScrollDebug] 配置后 - hidden: %@, enabled: %@, style: %ld",
            vScroller.hidden ? @"YES" : @"NO",
            vScroller.enabled ? @"YES" : @"NO", (long)vScroller.scrollerStyle);
      NSLog(@"[ScrollDebug] 滚动条 frame: %@",
            NSStringFromRect(vScroller.frame));

      NSLog(@"[BookmarkControl] 滚动条已强制显示，样式: %ld",
            (long)vScroller.scrollerStyle);
    } else {
      NSLog(@"[ScrollDebug] ❌ verticalScroller 仍然为 nil！");

      // 尝试重新创建滚动条
      NSLog(@"[ScrollDebug] 尝试重新设置滚动条...");
      self.outlineScroll.hasVerticalScroller = NO;
      self.outlineScroll.hasVerticalScroller = YES;

      vScroller = self.outlineScroll.verticalScroller;
      if (vScroller) {
        NSLog(@"[ScrollDebug] ✅ 重新创建滚动条成功！");
        [vScroller setEnabled:YES];
        [vScroller setHidden:NO];
        [vScroller setNeedsDisplay:YES];
      } else {
        NSLog(@"[ScrollDebug] ❌ 重新创建滚动条失败！");
      }
    }
  } else {
    NSLog(@"[ScrollDebug] 内容较少，滚动条可能自动隐藏");
    NSLog(@"[ScrollDebug] 但仍然尝试确保滚动条存在...");

    // 即使内容较少，也确保滚动条存在（可能处于禁用状态）
    self.outlineScroll.hasVerticalScroller = YES;
    NSScroller* vScroller = self.outlineScroll.verticalScroller;
    if (vScroller) {
      NSLog(@"[ScrollDebug] 滚动条存在，frame: %@",
            NSStringFromRect(vScroller.frame));
    }
  }

  // 刷新滚动视图
  [self.outlineScroll setNeedsDisplay:YES];
  [self.outlineScroll.contentView setNeedsDisplay:YES];

  NSLog(@"[ScrollDebug] ========== ensureBookmarkScrollBarVisible 结束 "
        @"==========");
}

- (void)forceTraditionalScrollBar {
  NSLog(@"[ScrollDebug] ========== 强制使用传统滚动条样式 ==========");

  if (!self.outlineScroll) {
    NSLog(@"[ScrollDebug] ❌ outlineScroll 为 nil，无法设置滚动条样式");
    return;
  }

  // 强制使用传统滚动条样式，更容易看到
  self.outlineScroll.scrollerStyle = NSScrollerStyleLegacy;
  self.outlineScroll.autohidesScrollers = NO;
  self.outlineScroll.hasVerticalScroller = YES;

  NSLog(@"[ScrollDebug] 设置为传统滚动条样式");

  NSScroller* vScroller = self.outlineScroll.verticalScroller;
  if (vScroller) {
    vScroller.scrollerStyle = NSScrollerStyleLegacy;
    vScroller.controlSize = NSControlSizeRegular;
    [vScroller setEnabled:YES];
    [vScroller setHidden:NO];
    [vScroller setNeedsDisplay:YES];

    NSLog(@"[ScrollDebug] 传统滚动条配置完成");
    NSLog(@"[ScrollDebug] 滚动条 frame: %@", NSStringFromRect(vScroller.frame));
    NSLog(@"[ScrollDebug] 滚动条 style: %ld", (long)vScroller.scrollerStyle);
  } else {
    NSLog(@"[ScrollDebug] ❌ 无法获取垂直滚动条");
  }

  // 强制刷新
  [self.outlineScroll setNeedsDisplay:YES];
  [self.outlineScroll.contentView setNeedsDisplay:YES];

  NSLog(@"[ScrollDebug] ========== 传统滚动条样式设置完成 ==========");
}

- (void)checkScrollBarOverlap {
  NSLog(@"[ScrollDebug] ========== 检查滚动条遮挡情况 ==========");

  if (!self.outlineScroll || self.outlineScroll.hidden) {
    NSLog(@"[ScrollDebug] 滚动视图不存在或被隐藏，跳过检查");
    return;
  }

  NSScroller* vScroller = self.outlineScroll.verticalScroller;
  if (!vScroller) {
    NSLog(@"[ScrollDebug] ❌ 垂直滚动条不存在");
    return;
  }

  NSLog(@"[ScrollDebug] 滚动条信息:");
  NSLog(@"[ScrollDebug] - frame: %@", NSStringFromRect(vScroller.frame));
  NSLog(@"[ScrollDebug] - bounds: %@", NSStringFromRect(vScroller.bounds));
  NSLog(@"[ScrollDebug] - superview: %@", vScroller.superview);
  NSLog(@"[ScrollDebug] - hidden: %@", vScroller.hidden ? @"YES" : @"NO");
  NSLog(@"[ScrollDebug] - alphaValue: %.2f", vScroller.alphaValue);

  // 检查滚动视图的布局
  NSLog(@"[ScrollDebug] 滚动视图布局:");
  NSLog(@"[ScrollDebug] - outlineScroll frame: %@",
        NSStringFromRect(self.outlineScroll.frame));
  NSLog(@"[ScrollDebug] - outlineScroll bounds: %@",
        NSStringFromRect(self.outlineScroll.bounds));
  NSLog(@"[ScrollDebug] - contentView frame: %@",
        NSStringFromRect(self.outlineScroll.contentView.frame));
  NSLog(@"[ScrollDebug] - documentView frame: %@",
        NSStringFromRect(self.outlineScroll.documentView.frame));

  // 检查左侧面板的所有子视图
  NSLog(@"[ScrollDebug] 左侧面板子视图:");
  for (NSUInteger i = 0; i < self.leftPanel.subviews.count; i++) {
    NSView* subview = self.leftPanel.subviews[i];
    NSRect subviewFrame = subview.frame;
    NSRect scrollerFrame = vScroller.frame;

    // 转换坐标系进行比较
    NSRect scrollerInPanel = [self.leftPanel convertRect:scrollerFrame
                                                fromView:vScroller.superview];

    BOOL overlaps = NSIntersectsRect(subviewFrame, scrollerInPanel);

    NSLog(@"[ScrollDebug] - subview[%lu]: %@ frame: %@ %@", (unsigned long)i,
          NSStringFromClass([subview class]), NSStringFromRect(subviewFrame),
          overlaps ? @"⚠️ 可能遮挡滚动条" : @"✅ 无遮挡");
  }

  NSLog(@"[ScrollDebug] ========== 滚动条遮挡检查完成 ==========");
}

- (void)ensureLeftPanelSize {
  NSLog(@"[ScrollDebug] ========== 确保左侧面板尺寸正确 ==========");

  CGFloat expectedWidth =
      self.bookmarkVisible ? kBookmarkExpandedWidth : kBookmarkCollapsedWidth;
  NSRect currentFrame = self.leftPanel.frame;

  NSLog(@"[ScrollDebug] 当前面板宽度: %.1f, 期望宽度: %.1f",
        currentFrame.size.width, expectedWidth);

  if (fabs(currentFrame.size.width - expectedWidth) > 1.0) {
    NSLog(@"[ScrollDebug] ⚠️ 面板宽度不匹配，强制修正");

    // 强制修正面板宽度
    NSRect correctedFrame = currentFrame;
    correctedFrame.size.width = expectedWidth;
    self.leftPanel.frame = correctedFrame;

    // 同时修正分割视图位置
    [self.appDelegate.split setPosition:expectedWidth ofDividerAtIndex:0];

    NSLog(@"[ScrollDebug] ✅ 面板宽度已修正为: %@",
          NSStringFromRect(self.leftPanel.frame));
  } else {
    NSLog(@"[ScrollDebug] ✅ 面板宽度正确");
  }

  // 如果书签可见，确保滚动视图frame正确
  if (self.bookmarkVisible && self.outlineScroll) {
    NSRect expectedScrollFrame =
        NSMakeRect(0, 0, kBookmarkExpandedWidth,
                   self.leftPanel.bounds.size.height - kControlBarHeight);
    NSRect currentScrollFrame = self.outlineScroll.frame;

    NSLog(@"[ScrollDebug] 滚动视图当前frame: %@",
          NSStringFromRect(currentScrollFrame));
    NSLog(@"[ScrollDebug] 滚动视图期望frame: %@",
          NSStringFromRect(expectedScrollFrame));

    if (!NSEqualRects(currentScrollFrame, expectedScrollFrame)) {
      NSLog(@"[ScrollDebug] ⚠️ 滚动视图frame不匹配，强制修正");
      self.outlineScroll.frame = expectedScrollFrame;
      NSLog(@"[ScrollDebug] ✅ 滚动视图frame已修正");
    }
  }

  NSLog(@"[ScrollDebug] ========== 左侧面板尺寸检查完成 ==========");
}

- (void)updateExpandedControlBarLayout {
  NSLog(@"[ScrollDebug] ========== 更新展开状态控制栏布局 ==========");

  if (!self.bookmarkVisible || !self.expandedTopControlBar) {
    NSLog(@"[ScrollDebug] 书签未展开或控制栏不存在，跳过更新");
    return;
  }

  // 计算正确的控制栏位置和大小
  CGFloat expandedWidth =
      self.leftPanel.bounds.size.width;  // 使用实际面板宽度而不是常量
  CGFloat controlBarY = self.leftPanel.bounds.size.height - kControlBarHeight;
  NSRect correctFrame =
      NSMakeRect(0, controlBarY, expandedWidth, kControlBarHeight);
  NSRect currentFrame = self.expandedTopControlBar.frame;

  NSLog(@"[ScrollDebug] 控制栏当前frame: %@", NSStringFromRect(currentFrame));
  NSLog(@"[ScrollDebug] 控制栏期望frame: %@", NSStringFromRect(correctFrame));
  NSLog(@"[ScrollDebug] 左侧面板bounds: %@",
        NSStringFromRect(self.leftPanel.bounds));
  NSLog(@"[ScrollDebug] 使用实际面板宽度: %.1f", expandedWidth);

  // 总是更新控制栏frame和子视图位置
  self.expandedTopControlBar.frame = correctFrame;

  // 更新子视图的位置和大小
  for (NSView* subview in self.expandedTopControlBar.subviews) {
    if (subview.frame.size.height == 1) {  // 分隔线
      NSRect separatorFrame = subview.frame;
      separatorFrame.size.width = expandedWidth;
      subview.frame = separatorFrame;
      NSLog(@"[ScrollDebug] 分隔线宽度已更新: %.1f", expandedWidth);
    } else if ([subview isKindOfClass:[NSButton class]]) {
      NSButton* button = (NSButton*)subview;
      if ([button.title isEqualToString:@"◀"]) {  // 收起按钮
        // 重新计算按钮位置（右对齐）
        CGFloat buttonWidth = 16;
        CGFloat buttonHeight = 16;
        CGFloat rightMargin = 4;
        CGFloat yCenter = (kControlBarHeight - buttonHeight) / 2;
        CGFloat buttonX = expandedWidth - buttonWidth - rightMargin;
        NSRect newButtonFrame =
            NSMakeRect(buttonX, yCenter, buttonWidth, buttonHeight);
        button.frame = newButtonFrame;
        NSLog(@"[ScrollDebug] ◀按钮位置已更新: %@",
              NSStringFromRect(newButtonFrame));
      }
    }
  }

  NSLog(@"[ScrollDebug] ✅ 控制栏布局更新完成");

  NSLog(@"[ScrollDebug] ========== 控制栏布局更新完成 ==========");
}

@end
