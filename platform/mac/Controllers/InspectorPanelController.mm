#import "InspectorPanelController.h"
#import "../Views/SelectableTextView.h"
#import "../Views/PdfView.h"
#include "platform/shared/pdfium_object_info.h"
#include "public/fpdf_doc.h"
#include "public/fpdf_edit.h"
#include "public/fpdf_annot.h"

// 界面布局常量
static const CGFloat kInspectorWidth = 300.0;
static const CGFloat kControlBarHeight = 30.0;

// 前向声明AppDelegate，避免循环依赖
@interface AppDelegate : NSObject
@property(nonatomic, strong) PdfView* view;
@property(nonatomic, strong) NSView* pdfContentView;
@property(nonatomic, strong) NSWindow* window;
@end

@implementation InspectorPanelController

- (void)createInspectorPanel {
  NSLog(@"[Inspector] 开始创建检查器面板");

  // 创建检查器面板容器
  self.inspectorPanel = [[NSView alloc]
      initWithFrame:NSMakeRect(0, 0, kInspectorWidth,
                               self.rightPanel.bounds.size.height)];
  self.inspectorPanel.autoresizingMask =
      NSViewWidthSizable | NSViewHeightSizable;
  self.inspectorPanel.wantsLayer = YES;
  self.inspectorPanel.layer.backgroundColor =
      [[NSColor controlBackgroundColor] CGColor];

  // 添加标题栏
  NSView* titleBar = [[NSView alloc]
      initWithFrame:NSMakeRect(0,
                               self.inspectorPanel.bounds.size.height -
                                   kControlBarHeight,
                               kInspectorWidth, kControlBarHeight)];
  titleBar.wantsLayer = YES;
  titleBar.layer.backgroundColor = [[NSColor windowBackgroundColor] CGColor];
  titleBar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;

  // 添加标题
  NSTextField* titleLabel =
      [[NSTextField alloc] initWithFrame:NSMakeRect(10, 6, 100, 18)];
  titleLabel.stringValue = @"页面元素";
  titleLabel.font = [NSFont boldSystemFontOfSize:13];
  titleLabel.textColor = [NSColor labelColor];
  titleLabel.backgroundColor = [NSColor clearColor];
  titleLabel.bordered = NO;
  titleLabel.editable = NO;
  titleLabel.selectable = NO;
  [titleBar addSubview:titleLabel];

  // 添加收起按钮
  NSButton* collapseButton = [[NSButton alloc]
      initWithFrame:NSMakeRect(kInspectorWidth - 30, 5, 20, 20)];
  collapseButton.title = @"◀";
  collapseButton.font = [NSFont systemFontOfSize:10];
  collapseButton.bordered = NO;
  collapseButton.target = self;
  collapseButton.action = @selector(toggleInspectorVisibility:);
  collapseButton.autoresizingMask = NSViewMinXMargin;
  [titleBar addSubview:collapseButton];

  // 添加底部分隔线
  NSView* separator =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kInspectorWidth, 1)];
  separator.wantsLayer = YES;
  separator.layer.backgroundColor = [[NSColor separatorColor] CGColor];
  separator.autoresizingMask = NSViewWidthSizable;
  [titleBar addSubview:separator];

  [self.inspectorPanel addSubview:titleBar];

  // 创建文本视图用于显示页面信息(使用自定义类支持Cmd+A)
  NSRect textFrame =
      NSMakeRect(0, 0, kInspectorWidth,
                 self.inspectorPanel.bounds.size.height - kControlBarHeight);
  self.inspectorTextView = [[SelectableTextView alloc] initWithFrame:textFrame];
  self.inspectorTextView.editable = NO;
  self.inspectorTextView.selectable = YES;

  // 启用 Cmd+A 全选功能
  self.inspectorTextView.usesFindPanel = YES;
  self.inspectorTextView.allowsUndo = NO;

  // 初始化对象位置映射
  self.objectPositions = [[NSMutableDictionary alloc] init];
  self.inspectorTextView.delegate = (id)self;  // 设置代理以处理点击事件
  self.inspectorTextView.font =
      [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
  self.inspectorTextView.textColor = [NSColor labelColor];
  self.inspectorTextView.backgroundColor = [NSColor textBackgroundColor];

  // 设置自动换行和文本容器属性
  self.inspectorTextView.textContainer.containerSize =
      NSMakeSize(textFrame.size.width, CGFLOAT_MAX);
  self.inspectorTextView.textContainer.widthTracksTextView = YES;
  self.inspectorTextView.textContainer.heightTracksTextView = NO;
  self.inspectorTextView.textContainer.lineBreakMode =
      NSLineBreakByWordWrapping;

  // 设置文本视图的自动调整行为
  self.inspectorTextView.autoresizingMask =
      NSViewWidthSizable | NSViewHeightSizable;
  self.inspectorTextView.horizontallyResizable = NO;  // 禁用水平调整
  self.inspectorTextView.verticallyResizable = YES;   // 启用垂直调整

  // 添加鼠标点击事件监听
  NSClickGestureRecognizer* clickGesture = [[NSClickGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(inspectorTextViewClicked:)];
  [self.inspectorTextView addGestureRecognizer:clickGesture];

  NSLog(@"[Inspector] 文本视图自动换行配置完成，容器宽度: %.1f",
        textFrame.size.width);

  // 创建滚动视图
  self.inspectorScrollView = [[NSScrollView alloc] initWithFrame:textFrame];
  self.inspectorScrollView.documentView = self.inspectorTextView;
  self.inspectorScrollView.hasVerticalScroller = YES;
  self.inspectorScrollView.hasHorizontalScroller = YES;
  self.inspectorScrollView.autoresizingMask =
      NSViewWidthSizable | NSViewHeightSizable;
  [self.inspectorPanel addSubview:self.inspectorScrollView];

  NSLog(@"[Inspector] 检查器面板创建完成");
}

- (void)toggleInspectorVisibility:(id)sender {
  NSLog(@"[Inspector] 切换检查器可见性，当前状态: %@",
        self.inspectorVisible ? @"可见" : @"隐藏");
  [self setInspectorVisible:!self.inspectorVisible animated:YES];
}

- (void)setInspectorVisible:(BOOL)visible animated:(BOOL)animated {
  if (self.inspectorVisible == visible) {
    return;  // 状态未改变
  }

  self.inspectorVisible = visible;
  NSLog(@"[Inspector] 设置检查器可见性: %@", visible ? @"显示" : @"隐藏");

  // 更新按钮文本
  // 检查器隐藏时显示◀（表示点击打开右侧窗口），检查器显示时显示▶（表示点击关闭右侧窗口）
  self.inspectorToggleButton.title = visible ? @"▶" : @"◀";

  // 获取右侧分割视图
  NSSplitView* rightSplit = (NSSplitView*)self.rightPanel.subviews.firstObject;
  if (![rightSplit isKindOfClass:[NSSplitView class]]) {
    return;
  }

  // 使用 NSSplitView 的折叠功能来完全收起/展开面板
  // inspectorPanel 是第二个子视图（index 1）
  BOOL inspectorAttached =
      [rightSplit.subviews containsObject:self.inspectorPanel];

  if (visible) {
    // 确保检查器面板已经添加到 split view 中
    if (!inspectorAttached) {
      [rightSplit addSubview:self.inspectorPanel];
    }

    // 展开：显示检查器面板
    CGFloat newPosition = self.rightPanel.bounds.size.width - kInspectorWidth;

    // 先取消隐藏，让 NSSplitView 知道需要为该子视图分配空间
    self.inspectorPanel.hidden = NO;

    // 立即调整现有子视图，防止旧尺寸影响布局
    [rightSplit adjustSubviews];

    // 设置新的分割位置
    [rightSplit setPosition:newPosition ofDividerAtIndex:0];
    [rightSplit layoutSubtreeIfNeeded];

    NSLog(@"[Inspector] 检查器面板展开，frame: %@",
          NSStringFromRect(self.inspectorPanel.frame));

    // 更新面板布局和内容
    [self updateInspectorLayout];
    [self updateInspectorContent];
  } else {
    // 收起：完全隐藏检查器面板
    CGFloat collapsedPosition = self.rightPanel.bounds.size.width;

    NSLog(@"[Inspector] 收起检查器，rightPanel宽度: %.1f, 目标位置: %.1f",
          self.rightPanel.bounds.size.width, collapsedPosition);

    // 设置位置，让 PDF 内容占满
    [rightSplit setPosition:collapsedPosition ofDividerAtIndex:0];
    [rightSplit layoutSubtreeIfNeeded];

    // 隐藏检查器面板
    self.inspectorPanel.hidden = YES;

    // 从 split view 中移除检查器面板，防止占用布局空间
    if (inspectorAttached) {
      [self.inspectorPanel removeFromSuperview];
      [rightSplit adjustSubviews];
    }

    NSLog(@"[Inspector] 检查器收起完成，pdfContentView frame: %@, "
          @"inspectorPanel frame: %@, 按钮 frame: %@",
          NSStringFromRect(self.appDelegate.pdfContentView.frame),
          NSStringFromRect(self.inspectorPanel.frame),
          NSStringFromRect(self.inspectorToggleButton.frame));
  }
}

- (void)updateInspectorLayout {
  if (!self.inspectorVisible || !self.inspectorTextView) {
    return;
  }

  // 更新文本容器大小以适应窗口变化
  NSRect currentFrame = self.inspectorScrollView.frame;
  CGFloat newWidth = currentFrame.size.width - 20;  // 减去滚动条和边距

  self.inspectorTextView.textContainer.containerSize =
      NSMakeSize(newWidth, CGFLOAT_MAX);
  [self.inspectorTextView setNeedsDisplay:YES];

  NSLog(@"[Inspector] 文本容器宽度已更新为: %.1f", newWidth);
}

// 递归显示对象树节点
- (void)displayObjectTreeNode:(PDFIUM_EX_OBJECT_TREE_NODE*)node
             attributedString:(NSMutableAttributedString*)attributedInfo
                  normalAttrs:(NSDictionary*)normalAttrs
                  objNumAttrs:(NSDictionary*)objNumAttrs {
  if (!node || !attributedInfo || !normalAttrs || !objNumAttrs) {
    return;
  }

  // 安全检查：防止递归过深
  if (node->depth > 10) {
    NSString* warningStr = [NSString
        stringWithFormat:@"[警告] 对象 %u 递归深度过深，已停止展开\n\n",
                         node->obj_num];
    [attributedInfo appendAttributedString:[[NSAttributedString alloc]
                                               initWithString:warningStr
                                                   attributes:normalAttrs]];
    return;
  }

  // 记录对象在文本中的位置（用于点击跳转）
  NSUInteger objStartPosition = attributedInfo.length;
  NSString* objKey = [NSString stringWithFormat:@"%u", node->obj_num];
  [self.objectPositions setObject:@(objStartPosition) forKey:objKey];

  // 显示对象号（天空蓝色）
  NSString* objNumStr =
      [NSString stringWithFormat:@"%u %u obj", node->obj_num, node->gen_num];
  if (objNumStr) {
    [attributedInfo appendAttributedString:[[NSAttributedString alloc]
                                               initWithString:objNumStr
                                                   attributes:objNumAttrs]];
  }
  [attributedInfo appendAttributedString:[[NSAttributedString alloc]
                                             initWithString:@"\n<<\n"
                                                 attributes:normalAttrs]];

  // 显示对象内容（安全检查）
  if (node->raw_content && strlen(node->raw_content) > 0) {
    NSString* contentStr = [NSString stringWithUTF8String:node->raw_content];
    if (contentStr && contentStr.length > 0) {
      // 创建带颜色的内容字符串，将对象引用标记为绿色
      NSMutableAttributedString* coloredContent =
          [self colorizeObjectReferences:contentStr normalAttrs:normalAttrs];
      [attributedInfo appendAttributedString:coloredContent];
      [attributedInfo appendAttributedString:[[NSAttributedString alloc]
                                                 initWithString:@"\n"
                                                     attributes:normalAttrs]];
    }
  }

  [attributedInfo appendAttributedString:[[NSAttributedString alloc]
                                             initWithString:@">>\nendobj\n\n"
                                                 attributes:normalAttrs]];

  // 如果有子节点，直接显示子节点（添加安全检查）
  if (node->children && node->child_count > 0) {
    // 限制显示的子节点数量，避免界面卡顿
    int maxDisplayChildren = 1000;
    int displayCount = (node->child_count < maxDisplayChildren)
                           ? node->child_count
                           : maxDisplayChildren;

    for (int i = 0; i < displayCount; i++) {
      if (node->children[i]) {
        [self displayObjectTreeNode:node->children[i]
                   attributedString:attributedInfo
                        normalAttrs:normalAttrs
                        objNumAttrs:objNumAttrs];
      }
    }

    // 如果子节点数量超过限制，显示提示信息
    if (node->child_count > maxDisplayChildren) {
      NSString* warningStr = [NSString
          stringWithFormat:@"[提示] 对象 %u 有 %d 个子节点，仅显示前 %d 个\n\n",
                           node->obj_num, node->child_count,
                           maxDisplayChildren];
      [attributedInfo appendAttributedString:[[NSAttributedString alloc]
                                                 initWithString:warningStr
                                                     attributes:normalAttrs]];
    }
  }
}

- (void)updateInspectorContent {
  if (!self.inspectorVisible || !self.inspectorTextView || !self.appDelegate.view) {
    return;
  }

  FPDF_DOCUMENT doc = [self.appDelegate.view document];
  if (!doc) {
    self.inspectorTextView.string = @"没有打开的PDF文档";
    return;
  }

  int currentPage = [self.appDelegate.view currentPageIndex];
  int totalPages = FPDF_GetPageCount(doc);

  // 获取当前页面
  FPDF_PAGE page = FPDF_LoadPage(doc, currentPage);
  if (!page) {
    self.inspectorTextView.string = @"无法加载当前页面";
    return;
  }

  // 获取页面尺寸
  double pageWidth = FPDF_GetPageWidth(page);
  double pageHeight = FPDF_GetPageHeight(page);

  // 获取页面对象数量（内容流中的绘图对象）
  int pageObjectCount = FPDFPage_CountObjects(page);

  // 获取注释数量
  int annotCount = FPDFPage_GetAnnotCount(page);

  // 构建带颜色的属性文本
  NSMutableAttributedString* attributedInfo =
      [[NSMutableAttributedString alloc] init];

  // 基础文本属性
  NSDictionary* normalAttrs = @{
    NSForegroundColorAttributeName : [NSColor textColor],
    NSFontAttributeName :
        [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular]
  };

  // 天空蓝色对象号属性
  NSDictionary* objNumAttrs = @{
    NSForegroundColorAttributeName : [NSColor systemBlueColor],
    NSFontAttributeName : [NSFont monospacedSystemFontOfSize:12
                                                      weight:NSFontWeightBold]
  };

  // 清空对象位置映射
  [self.objectPositions removeAllObjects];

  // 构建PDF对象引用树
  PDFIUM_EX_OBJECT_TREE_NODE* object_tree =
      PdfiumEx_BuildObjectTree(doc, page, 1000000);  // 最大深度，支持完整分析

  // 统计对象树中的总对象数
  int totalObjectCount = 0;
  if (object_tree) {
    totalObjectCount = PdfiumEx_CountObjectTreeNodes(object_tree);
  }

  // 添加基础信息
  NSString* basicInfo = [NSString
      stringWithFormat:@"PDF 文档信息\n================\n\n当前页面: %d / "
                       @"%d\n页面尺寸: %.2f x %.2f pt\n"
                       @"页面绘图对象: %d\n注释对象: %d\n对象树节点数: %d\n\n"
                       @"PDF对象引用树\n================\n",
                       currentPage + 1, totalPages, pageWidth, pageHeight,
                       pageObjectCount, annotCount, totalObjectCount];
  [attributedInfo appendAttributedString:[[NSAttributedString alloc]
                                             initWithString:basicInfo
                                                 attributes:normalAttrs]];

  if (object_tree) {
    // 递归显示树结构
    [self displayObjectTreeNode:object_tree
               attributedString:attributedInfo
                    normalAttrs:normalAttrs
                    objNumAttrs:objNumAttrs];

    PdfiumEx_ReleaseObjectTree(object_tree);
  } else {
    // 如果对象树不可用，显示提示信息
    NSString* treeInfo = @"\n注意: PDF对象引用树功能暂未实现\n";
    [attributedInfo appendAttributedString:[[NSAttributedString alloc]
                                               initWithString:treeInfo
                                                   attributes:normalAttrs]];
  }

  FPDF_ClosePage(page);

  // 更新文本视图
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.inspectorTextView.textStorage setAttributedString:attributedInfo];
    NSLog(@"[Inspector] 检查器内容已更新，页面 %d", currentPage + 1);
  });
}

- (NSMutableAttributedString*)colorizeObjectReferences:(NSString*)text
                                           normalAttrs:
                                               (NSDictionary*)normalAttrs {
  NSMutableAttributedString* result =
      [[NSMutableAttributedString alloc] initWithString:text
                                             attributes:normalAttrs];

  // 创建绿色属性
  NSDictionary* greenAttrs = @{
    NSForegroundColorAttributeName : [NSColor systemGreenColor],
    NSFontAttributeName : [NSFont monospacedSystemFontOfSize:12
                                                      weight:NSFontWeightBold]
  };

  // 查找所有对象引用（格式：数字 0 R）
  NSError* error = nil;
  NSRegularExpression* regex = [NSRegularExpression
      regularExpressionWithPattern:@"\\b(\\d+)\\s+0\\s+R\\b"
                           options:0
                             error:&error];
  if (error) {
    NSLog(@"[Inspector] 对象引用正则表达式错误: %@",
          error.localizedDescription);
    return result;
  }

  // 应用绿色到所有匹配的对象引用
  [regex enumerateMatchesInString:text
                          options:0
                            range:NSMakeRange(0, text.length)
                       usingBlock:^(NSTextCheckingResult* match,
                                    NSMatchingFlags flags, BOOL* stop) {
                         NSRange matchRange = [match range];
                         [result setAttributes:greenAttrs range:matchRange];
                       }];

  return result;
}

- (void)inspectorTextViewClicked:(NSClickGestureRecognizer*)recognizer {
  if (!self.inspectorTextView || !self.objectPositions) {
    return;
  }

  NSPoint clickPoint = [recognizer locationInView:self.inspectorTextView];

  // 获取点击位置的字符索引
  NSUInteger charIndex =
      [self.inspectorTextView characterIndexForInsertionAtPoint:clickPoint];
  NSString* text = self.inspectorTextView.string;

  NSLog(@"[Inspector] 点击位置: (%.1f, %.1f), 字符索引: %lu", clickPoint.x,
        clickPoint.y, charIndex);

  // 查找点击位置附近的对象引用（格式：数字 0 R）
  NSError* error = nil;
  NSRegularExpression* regex =
      [NSRegularExpression regularExpressionWithPattern:@"(\\d+)\\s+0\\s+R"
                                                options:0
                                                  error:&error];
  if (error) {
    NSLog(@"[Inspector] 正则表达式错误: %@", error.localizedDescription);
    return;
  }

  __block uint32_t targetObjNum = 0;
  __block NSRange foundRange = NSMakeRange(NSNotFound, 0);
  [regex enumerateMatchesInString:text
                          options:0
                            range:NSMakeRange(0, text.length)
                       usingBlock:^(NSTextCheckingResult* match,
                                    NSMatchingFlags flags, BOOL* stop) {
                         NSRange matchRange = [match range];
                         NSLog(@"[Inspector] 找到匹配: %@, 范围: %@",
                               [text substringWithRange:matchRange],
                               NSStringFromRange(matchRange));

                         if (charIndex >= matchRange.location &&
                             charIndex <=
                                 matchRange.location + matchRange.length) {
                           NSString* objNumStr =
                               [text substringWithRange:[match rangeAtIndex:1]];
                           targetObjNum = (uint32_t)[objNumStr integerValue];
                           foundRange = matchRange;
                           NSLog(@"[Inspector] 点击命中对象引用: %u",
                                 targetObjNum);
                           *stop = YES;
                         }
                       }];

  // 如果找到目标对象号，跳转到对应位置
  if (targetObjNum > 0) {
    NSString* objKey = [NSString stringWithFormat:@"%u", targetObjNum];
    NSNumber* position = [self.objectPositions objectForKey:objKey];
    NSLog(@"[Inspector] 查找对象 %u 的位置，映射表中有 %lu 个对象",
          targetObjNum, self.objectPositions.count);

    if (position) {
      NSUInteger targetPos = [position unsignedIntegerValue];
      NSRange targetRange = NSMakeRange(targetPos, 0);
      [self.inspectorTextView scrollRangeToVisible:targetRange];
      [self.inspectorTextView
          setSelectedRange:NSMakeRange(targetPos, 20)];  // 高亮显示更多字符
      NSLog(@"[Inspector] 成功跳转到对象 %u，位置：%lu", targetObjNum,
            targetPos);
    } else {
      NSLog(@"[Inspector] 未找到对象 %u 的位置信息", targetObjNum);
      // 打印所有可用的对象号
      NSArray* allKeys = [self.objectPositions.allKeys
          sortedArrayUsingSelector:@selector(compare:)];
      NSLog(@"[Inspector] 可用对象号: %@", allKeys);
    }
  } else {
    NSLog(@"[Inspector] 点击位置未找到对象引用");
  }
}

@end

