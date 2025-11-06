#import <Cocoa/Cocoa.h>

@class AppDelegate;
@class SelectableTextView;
@class PdfView;

// 检查器面板控制器 - 负责检查器面板UI和PDF对象树显示
@interface InspectorPanelController : NSObject

@property(nonatomic, weak) AppDelegate* appDelegate;
@property(nonatomic, weak) PdfView* pdfView;
@property(nonatomic, strong) NSView* inspectorPanel;
@property(nonatomic, strong) NSButton* inspectorToggleButton;
@property(nonatomic, assign) BOOL inspectorVisible;
@property(nonatomic, strong) SelectableTextView* inspectorTextView;
@property(nonatomic, strong) NSScrollView* inspectorScrollView;
@property(nonatomic, strong) NSMutableDictionary* objectPositions;
@property(nonatomic, strong) NSView* rightPanel;

- (void)createInspectorPanel;
- (void)toggleInspectorVisibility:(id)sender;
- (void)setInspectorVisible:(BOOL)visible animated:(BOOL)animated;
- (void)updateInspectorLayout;
- (void)updateInspectorContent;
- (void)updateInspectorButtonPosition:(BOOL)visible;
- (void)inspectorTextViewClicked:(id)sender;

@end

