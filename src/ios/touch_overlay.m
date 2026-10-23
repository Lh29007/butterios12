// On-screen touch controls for the iOS 12 build (UIKit, no Swift).
// Joystick (left) -> arrow keys. Buttons (right) -> Z, X, C, Enter, Shift, Esc.
// Options (remapping, layout, on/off) live in the launcher, not in the game.

#import <UIKit/UIKit.h>
#import <SDL2/SDL.h>
#import <SDL2/SDL_syswm.h>
#include <stdbool.h>
#include <math.h>
#include "touch_controls.h"
#include "bs_keys.h"

static NSString *const kPosStick = @"stick";
static NSString *const kPosZ = @"z";
static NSString *const kPosX = @"x";
static NSString *const kPosC = @"c";
static NSString *const kPosEnter = @"enter";
static NSString *const kPosShift = @"shift";
static NSString *const kPosEsc = @"esc";

static const CGFloat kStickDiameter = 170.0;
static const CGFloat kButtonDiameter = 64.0;
static const CGFloat kSmallDiameter = 44.0;
static const NSInteger kDoneTag = 9998;

static IOSTouchControlsKeyCallback gKeyCb = NULL;
static IOSTouchControlsExitCallback gExitCb = NULL;
static UIView *gOverlay = nil;
static UIWindow *gWindow = nil;
static BOOL gEditMode = NO;
static UILabel *gFpsLabel = nil;

static void sendKey(int vk, bool down) {
    if (gKeyCb) gKeyCb((int32_t)vk, down);
}

int BSMappedVK(int action) {
    NSString *k = [NSString stringWithFormat:@"bs.map.%s", kActions[action].key];
    NSInteger v = [[NSUserDefaults standardUserDefaults] integerForKey:k];
    return v ? (int)v : kActions[action].defVK;
}

static CGPoint savedFraction(NSString *posKey, CGPoint defFraction) {
    NSString *s = [[NSUserDefaults standardUserDefaults]
        stringForKey:[@"bs.pos." stringByAppendingString:posKey]];
    if (!s) return defFraction;
    NSArray *parts = [s componentsSeparatedByString:@","];
    if (parts.count != 2) return defFraction;
    return CGPointMake([parts[0] doubleValue], [parts[1] doubleValue]);
}

static void setEditMode(BOOL on);

// ---------------------------------------------------------------------------
// Control view: a joystick (stick) or a single key button.
// ---------------------------------------------------------------------------

@interface BSControlView : UIView {
    BOOL _dirs[4];
    BOOL _buttonHeld;
    UITouch *_active;
}
@property (nonatomic, assign) BOOL isStick;
@property (nonatomic, assign) int action;
@property (nonatomic, copy) NSString *posKey;
@property (nonatomic, strong) UIView *knob;
@property (nonatomic, strong) UIPanGestureRecognizer *pan;
- (void)setEditing:(BOOL)editing;
@end

@implementation BSControlView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.cornerRadius = frame.size.width / 2.0;
        self.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.18];
        self.layer.borderWidth = 1.5;
        self.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.5].CGColor;
        self.multipleTouchEnabled = YES;
    }
    return self;
}

- (void)setEditing:(BOOL)editing {
    if (editing && !self.pan) {
        self.pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)];
        [self addGestureRecognizer:self.pan];
    } else if (!editing && self.pan) {
        [self removeGestureRecognizer:self.pan];
        self.pan = nil;
    }
    UIColor *border = editing ? [UIColor yellowColor] : [[UIColor whiteColor] colorWithAlphaComponent:0.5];
    self.layer.borderColor = border.CGColor;
}

- (void)panned:(UIPanGestureRecognizer *)g {
    UIView *sup = self.superview;
    if (!sup) return;
    CGPoint p = [g locationInView:sup];
    if (g.state == UIGestureRecognizerStateChanged) {
        self.center = p;
    } else if (g.state == UIGestureRecognizerStateEnded) {
        CGFloat fx = p.x / sup.bounds.size.width;
        CGFloat fy = p.y / sup.bounds.size.height;
        [[NSUserDefaults standardUserDefaults]
            setObject:[NSString stringWithFormat:@"%f,%f", fx, fy]
               forKey:[@"bs.pos." stringByAppendingString:self.posKey]];
    }
}

- (void)setDirection:(int)i down:(BOOL)down {
    if (_dirs[i] == down) return;
    _dirs[i] = down;
    sendKey(BSMappedVK(i), down);  // i matches A_UP, A_DOWN, A_LEFT, A_RIGHT
}

- (void)updateStickWithTouch:(UITouch *)t {
    CGPoint p = [t locationInView:self];
    CGFloat r = self.bounds.size.width / 2.0;
    CGFloat dx = (p.x - r) / r;
    CGFloat dy = (p.y - r) / r;
    CGFloat mag = sqrt(dx * dx + dy * dy);
    if (mag > 1.0) { dx /= mag; dy /= mag; }
    self.knob.center = CGPointMake(r + dx * r * 0.6, r + dy * r * 0.6);
    const CGFloat th = 0.35;
    [self setDirection:A_UP down:(dy < -th)];
    [self setDirection:A_DOWN down:(dy > th)];
    [self setDirection:A_LEFT down:(dx < -th)];
    [self setDirection:A_RIGHT down:(dx > th)];
}

- (void)releaseStick {
    for (int i = 0; i < 4; i++) [self setDirection:i down:NO];
    self.knob.center = CGPointMake(self.bounds.size.width / 2.0, self.bounds.size.height / 2.0);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (gEditMode || _active) return;
    _active = [touches anyObject];
    if (self.isStick) {
        [self updateStickWithTouch:_active];
    } else if (!_buttonHeld) {
        _buttonHeld = YES;
        self.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.45];
        sendKey(BSMappedVK(self.action), true);
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_active || gEditMode || !self.isStick) return;
    if ([touches containsObject:_active]) [self updateStickWithTouch:_active];
}

- (void)endActiveTouch:(NSSet<UITouch *> *)touches {
    if (!_active || ![touches containsObject:_active]) return;
    _active = nil;
    if (self.isStick) {
        [self releaseStick];
    } else if (_buttonHeld) {
        _buttonHeld = NO;
        self.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.18];
        sendKey(BSMappedVK(self.action), false);
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self endActiveTouch:touches];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self endActiveTouch:touches];
}

@end

// ---------------------------------------------------------------------------
// Overlay: hit-tests only the controls, so everything else reaches SDL.
// ---------------------------------------------------------------------------

@interface BSOverlayView : UIView
@end

@implementation BSOverlayView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    for (UIView *v in [self.subviews reverseObjectEnumerator]) {
        if (v.hidden || v.alpha < 0.01) continue;
        CGPoint p = [v convertPoint:point fromView:self];
        if ([v pointInside:p withEvent:event]) {
            return [v hitTest:p withEvent:event];
        }
    }
    return nil;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize s = self.bounds.size;
    for (UIView *v in self.subviews) {
        if (![v isKindOfClass:[BSControlView class]]) continue;
        BSControlView *c = (BSControlView *)v;
        CGFloat d = c.isStick ? kStickDiameter : (c.action == A_ESC ? kSmallDiameter : kButtonDiameter);
        CGPoint def = CGPointMake(0.5, 0.5);
        if (c.isStick) def = CGPointMake(0.14, 0.62);
        else if (c.action == A_Z) def = CGPointMake(0.92, 0.58);
        else if (c.action == A_X) def = CGPointMake(0.92, 0.80);
        else if (c.action == A_C) def = CGPointMake(0.78, 0.80);
        else if (c.action == A_ENTER) def = CGPointMake(0.78, 0.58);
        else if (c.action == A_SHIFT) def = CGPointMake(0.64, 0.80);
        else if (c.action == A_ESC) def = CGPointMake(0.80, 0.12);
        CGPoint f = savedFraction(c.posKey, def);
        c.bounds = CGRectMake(0, 0, d, d);
        c.layer.cornerRadius = d / 2.0;
        c.center = CGPointMake(f.x * s.width, f.y * s.height);
        if (c.isStick) c.knob.frame = CGRectMake(d * 0.3, d * 0.3, d * 0.4, d * 0.4);
    }
    UIView *done = [self viewWithTag:kDoneTag];
    if (done) done.center = CGPointMake(s.width * 0.5, s.height * 0.08);
}

- (void)doneTapped {
    setEditMode(NO);
}

@end

static void setEditMode(BOOL on) {
    gEditMode = on;
    if (!gOverlay) return;
    for (UIView *v in gOverlay.subviews) {
        if ([v isKindOfClass:[BSControlView class]]) {
            [(BSControlView *)v setEditing:on];
        }
    }
    UIView *done = [gOverlay viewWithTag:kDoneTag];
    done.hidden = !on;
}

static BSControlView *makeButton(int action, NSString *posKey) {
    CGFloat d = (action == A_ESC) ? kSmallDiameter : kButtonDiameter;
    BSControlView *c = [[BSControlView alloc] initWithFrame:CGRectMake(0, 0, d, d)];
    c.isStick = NO;
    c.action = action;
    c.posKey = posKey;
    UILabel *l = [[UILabel alloc] initWithFrame:c.bounds];
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    l.textAlignment = NSTextAlignmentCenter;
    l.textColor = [UIColor whiteColor];
    l.font = [UIFont boldSystemFontOfSize:(action == A_ESC) ? 11 : 18];
    l.text = [NSString stringWithUTF8String:kActions[action].label];
    l.userInteractionEnabled = NO;
    [c addSubview:l];
    return c;
}

static BSControlView *makeStick(void) {
    BSControlView *c = [[BSControlView alloc] initWithFrame:CGRectMake(0, 0, kStickDiameter, kStickDiameter)];
    c.isStick = YES;
    c.action = A_UP;
    c.posKey = kPosStick;
    UIView *knob = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 70, 70)];
    knob.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.35];
    knob.layer.cornerRadius = 35;
    knob.userInteractionEnabled = NO;
    [c addSubview:knob];
    c.knob = knob;
    return c;
}

// ---------------------------------------------------------------------------
// Public API (touch_controls.h)
// ---------------------------------------------------------------------------

bool IOSLauncher_touchControlsEnabled(void) {
    NSNumber *v = [[NSUserDefaults standardUserDefaults] objectForKey:@"bs.touch.enabled"];
    return v ? [v boolValue] : YES;
}

bool IOSLauncher_showFPSEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"bs.show.fps"];
}

void IOSTouchControls_install(void *sdlWindow, IOSTouchControlsKeyCallback callback,
                              IOSTouchControlsExitCallback exitCallback,
                              bool showControls, bool showFPS) {
    gKeyCb = callback;
    gExitCb = exitCallback;
    if ((!showControls && !showFPS) || !sdlWindow) return;

    SDL_SysWMinfo info;
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo((SDL_Window *)sdlWindow, &info) || info.subsystem != SDL_SYSWM_UIKIT) {
        return;
    }
    gWindow = info.info.uikit.window;
    if (!gWindow) return;

    [gOverlay removeFromSuperview];
    BSOverlayView *overlay = [[BSOverlayView alloc] initWithFrame:gWindow.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor clearColor];
    gOverlay = overlay;

    if (showControls) {
        [overlay addSubview:makeStick()];
        [overlay addSubview:makeButton(A_Z, kPosZ)];
        [overlay addSubview:makeButton(A_X, kPosX)];
        [overlay addSubview:makeButton(A_C, kPosC)];
        [overlay addSubview:makeButton(A_ENTER, kPosEnter)];
        [overlay addSubview:makeButton(A_SHIFT, kPosShift)];
        [overlay addSubview:makeButton(A_ESC, kPosEsc)];

        // "OK" button, only visible while moving buttons.
        UIButton *done = [UIButton buttonWithType:UIButtonTypeCustom];
        done.tag = kDoneTag;
        done.bounds = CGRectMake(0, 0, 90, 40);
        done.backgroundColor = [[UIColor yellowColor] colorWithAlphaComponent:0.8];
        done.layer.cornerRadius = 12;
        [done setTitle:@"OK" forState:UIControlStateNormal];
        [done setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
        done.hidden = YES;
        [done addTarget:overlay action:@selector(doneTapped) forControlEvents:UIControlEventTouchUpInside];
        [overlay addSubview:done];
    }

    // FPS counter, top left.
    gFpsLabel = nil;
    if (showFPS) {
        UILabel *fps = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, 120, 24)];
        fps.textColor = [UIColor greenColor];
        fps.font = [UIFont boldSystemFontOfSize:14];
        fps.text = @"FPS --";
        fps.userInteractionEnabled = NO;
        [overlay addSubview:fps];
        gFpsLabel = fps;
    }

    [gWindow addSubview:overlay];
    [overlay setNeedsLayout];

    // "Move buttons at next launch" is a one-shot flag: consume it here.
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (showControls && [d boolForKey:@"bs.edit.onstart"]) {
        [d setBool:NO forKey:@"bs.edit.onstart"];
        setEditMode(YES);
    }
}

void IOSTouchControls_remove(void) {
    [gOverlay removeFromSuperview];
    gOverlay = nil;
}

void IOSTouchControls_setFPS(double fps) {
    if (gFpsLabel) gFpsLabel.text = [NSString stringWithFormat:@"FPS %.0f", fps];
}
