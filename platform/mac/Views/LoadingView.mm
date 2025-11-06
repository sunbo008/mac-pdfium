//
// Copyright 2024 The PDFium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//

#import "LoadingView.h"

@implementation LoadingView {
  NSProgressIndicator* _spinner;
  NSTextField* _label;
  NSButton* _cancelButton;
  NSTimer* _ellipsisTimer;
  NSInteger _ellipsisCount;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self) {
    _ellipsisCount = 1;
    [self setupSubviews];
  }
  return self;
}

- (void)setupSubviews {
  // 半透明深色背景
  self.wantsLayer = YES;
  self.layer.backgroundColor =
      [[NSColor colorWithWhite:0.0 alpha:0.5] CGColor];

  // 创建中心容器视图
  NSView* container = [[NSView alloc] initWithFrame:NSZeroRect];
  container.translatesAutoresizingMaskIntoConstraints = NO;

  // 创建 Spinner（旋转指示器）
  _spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
  _spinner.style = NSProgressIndicatorStyleSpinning;
  _spinner.controlSize = NSControlSizeLarge;
  _spinner.translatesAutoresizingMaskIntoConstraints = NO;

  // 创建文字标签
  _label = [[NSTextField alloc] initWithFrame:NSZeroRect];
  _label.stringValue = @"正在加载文档.";
  _label.font = [NSFont systemFontOfSize:14];
  _label.textColor = [NSColor whiteColor];
  _label.backgroundColor = [NSColor clearColor];
  _label.editable = NO;
  _label.selectable = NO;
  _label.bordered = NO;
  _label.alignment = NSTextAlignmentCenter;
  _label.translatesAutoresizingMaskIntoConstraints = NO;

  // 创建取消按钮
  _cancelButton = [[NSButton alloc] initWithFrame:NSZeroRect];
  _cancelButton.title = @"取消";
  _cancelButton.bezelStyle = NSBezelStyleRounded;
  _cancelButton.target = self;
  _cancelButton.action = @selector(cancelButtonClicked:);
  _cancelButton.translatesAutoresizingMaskIntoConstraints = NO;

  // 添加子视图
  [container addSubview:_spinner];
  [container addSubview:_label];
  [container addSubview:_cancelButton];
  [self addSubview:container];

  // 布局约束
  [NSLayoutConstraint activateConstraints:@[
    // 容器居中
    [container.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
    [container.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],

    // Spinner 在顶部
    [_spinner.topAnchor constraintEqualToAnchor:container.topAnchor],
    [_spinner.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
    [_spinner.widthAnchor constraintEqualToConstant:32],
    [_spinner.heightAnchor constraintEqualToConstant:32],

    // 文字标签在 Spinner 下方，间距 16pt
    [_label.topAnchor constraintEqualToAnchor:_spinner.bottomAnchor
                                     constant:16],
    [_label.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
    [_label.widthAnchor constraintGreaterThanOrEqualToConstant:200],

    // 取消按钮在文字下方，间距 20pt
    [_cancelButton.topAnchor constraintEqualToAnchor:_label.bottomAnchor
                                            constant:20],
    [_cancelButton.centerXAnchor
        constraintEqualToAnchor:container.centerXAnchor],
    [_cancelButton.bottomAnchor
        constraintEqualToAnchor:container.bottomAnchor],
    [_cancelButton.widthAnchor constraintGreaterThanOrEqualToConstant:80],
  ]];
}

- (void)show {
  self.hidden = NO;
  [_spinner startAnimation:nil];

  // 启动省略号动画定时器（每 0.5 秒更新一次）
  _ellipsisCount = 1;
  _ellipsisTimer =
      [NSTimer scheduledTimerWithTimeInterval:0.5
                                       target:self
                                     selector:@selector(updateEllipsis)
                                     userInfo:nil
                                      repeats:YES];
}

- (void)hide {
  self.hidden = YES;
  [_spinner stopAnimation:nil];

  // 停止定时器
  if (_ellipsisTimer) {
    [_ellipsisTimer invalidate];
    _ellipsisTimer = nil;
  }
}

- (void)updateEllipsis {
  // 循环更新省略号：. -> .. -> ... -> .
  _ellipsisCount = (_ellipsisCount % 3) + 1;

  NSString* ellipsis = @"";
  for (NSInteger i = 0; i < _ellipsisCount; i++) {
    ellipsis = [ellipsis stringByAppendingString:@"."];
  }

  _label.stringValue =
      [NSString stringWithFormat:@"正在加载文档%@", ellipsis];
}

- (void)cancelButtonClicked:(id)sender {
  if (self.onCancel) {
    self.onCancel();
  }
}

- (void)dealloc {
  if (_ellipsisTimer) {
    [_ellipsisTimer invalidate];
  }
}

@end

