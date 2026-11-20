// YTHideProgress, YouTube part: hides the thin progress bar shown under a video while the
// player controls are hidden, in portrait only (tapping the video still shows the full seek
// bar), the progress line of the floating miniplayer, the watched bar on video thumbnails and,
// as an option, the length badge on them. Each has its own switch in YouTube's
// settings, under one Enabled switch that a player button (through YTVideoOverlay, when it is
// installed) also flips. The picture in picture switch is used by the SpringBoard part (SpringBoard.x).
// Works injected into a sideloaded YouTube app too; picture in picture then stays as it is.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <notify.h>

#define kMasterKey @"YTHideProgress_enabled" // also read by the SpringBoard part
#define kButtonKey @"YTHideProgress_button"  // YTVideoOverlay's toggle for the player button
#define kEnabledKey @"YTHideProgress_portrait"
#define kLandscapeKey @"YTHideProgress_landscape"
#define kCollabsKey @"YTHideProgress_collabs" // a video counts as listed if any of its channels is listed
#define kAlwaysKey @"YTHideProgress_withcontrols"
#define kMiniEnabledKey @"YTHideProgress_miniplayer"
#define kPiPKey @"YTHideProgress_pip"       // read by the SpringBoard part
#define kPiPBarKey @"YTHideProgress_pipbar" // read by the SpringBoard part
#define kLockKey @"YTHideProgress_lockscreen" // read by the SpringBoard part
#define kWatchedKey @"YTHideProgress_watchedbar"
#define kLengthKey @"YTHideProgress_length"
#define kSystemKey @"YTHideProgress_system" // read by the SpringBoard part at launch
#define kChannelsKey @"YTHideProgress_channels"       // [{ id, name }]
#define kChannelModeKey @"YTHideProgress_channelmode" // 0 all channels, 1 only listed, 2 all except listed
#define TweakSection ((NSInteger)'ythp')

@interface YTSettingsGroupData : NSObject
@property (nonatomic, assign) NSInteger type;
+ (NSMutableArray <NSNumber *> *)tweaks;
@end
@interface YTSettingsSectionItem : NSObject
+ (instancetype)switchItemWithTitle:(NSString *)title titleDescription:(NSString *)desc accessibilityIdentifier:(NSString *)axId
                           switchOn:(BOOL)on switchBlock:(BOOL (^)(id cell, BOOL enabled))block settingItemId:(int)itemId;
@end
@interface YTSettingsViewController : UIViewController
- (void)setSectionItems:(NSMutableArray *)items forCategory:(NSInteger)category title:(NSString *)title titleDescription:(NSString *)desc headerHidden:(BOOL)hidden;
- (void)setSectionItems:(NSMutableArray *)items forCategory:(NSInteger)category title:(NSString *)title icon:(id)icon titleDescription:(NSString *)desc headerHidden:(BOOL)hidden;
@end
@interface YTSettingsSectionItemManager : NSObject
- (void)updateYTHideProgressSectionWithEntry:(id)entry;
@end
@interface YTInlinePlayerBarContainerView : UIView
@end
@interface YTModularPlayerBarView : UIView
@end
@interface YTWatchFloatingMiniplayerProgressBarView : UIView
@end

// YTVideoOverlay (PoomSmart): adds tweak buttons to the player's top bar or bottom bar.
@interface YTSettingsSectionItemManager (YTVideoOverlay)
+ (void)registerTweak:(NSString *)tweakId metadata:(NSDictionary *)metadata;
@end
@interface YTQTMButton : UIButton
@end
@interface YTMainAppControlsOverlayView : UIView
@property (retain, nonatomic) NSMutableDictionary <NSString *, YTQTMButton *> *overlayButtons;
- (UIImage *)buttonImage:(NSString *)tweakId;
@end
@interface YTInlinePlayerBarContainerView (YTVideoOverlay)
@property (retain, nonatomic) NSMutableDictionary <NSString *, YTQTMButton *> *overlayButtons;
- (UIImage *)buttonImage:(NSString *)tweakId;
@end
@interface YTPlayerViewController : UIViewController
@end
@interface YTActionSheetAction : NSObject
+ (instancetype)actionWithTitle:(NSString *)title iconImage:(UIImage *)image style:(NSInteger)style handler:(void (^)(void))handler;
@end
@interface YTDefaultSheetController : NSObject
- (void)addAction:(YTActionSheetAction *)action;
- (UIView *)sourceView;
@end
@interface YTSettingsSectionItem (Picker)
+ (instancetype)itemWithTitle:(NSString *)title titleDescription:(NSString *)desc accessibilityIdentifier:(NSString *)axId
              detailTextBlock:(NSString *(^)(void))detail selectBlock:(BOOL (^)(id cell, NSUInteger arg1))select;
+ (instancetype)checkmarkItemWithTitle:(NSString *)title titleDescription:(NSString *)desc selectBlock:(BOOL (^)(id cell, NSUInteger arg1))select;
@end
@interface YTSettingsPickerViewController : UIViewController
- (instancetype)initWithNavTitle:(NSString *)navTitle pickerSectionTitle:(NSString *)sectionTitle rows:(NSArray *)rows
               selectedItemIndex:(NSUInteger)index parentResponder:(id)responder;
@end
@interface YTToastResponderEvent : NSObject
+ (instancetype)eventWithMessage:(NSString *)message firstResponder:(id)responder;
- (void)send;
@end

static BOOL gMaster = YES;      // cached; read at load, updated by the switches and the button
static BOOL gEnabled = YES;     // "Hide in Portrait"
static BOOL gLandscape = NO;    // "Hide in Landscape"
static BOOL gCollabs = YES;     // "Include Collaborators"
static BOOL gAlways = NO;       // "Hide With Controls"
static BOOL gWatched = YES;     // "Hide Watched Bar"
static BOOL gLength = NO;       // "Hide Video Length"
static BOOL gMiniEnabled = YES;
static BOOL gOverlayAvailable;  // YTVideoOverlay took the button

// Debug log, only in builds made with YTHP_DEBUG=1: <YouTube tmp>/ythideprogress.log
#ifdef YTHP_DEBUG
static void ythpLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ythideprogress.log"];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) { [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil]; h = [NSFileHandle fileHandleForWritingAtPath:path]; }
    [h seekToEndOfFile];
    [h writeData:[[NSString stringWithFormat:@"%.3f %@\n", CFAbsoluteTimeGetCurrent(), line] dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}
#define YTHP_LOG(...) ythpLog(__VA_ARGS__)
#else
#define YTHP_LOG(...) do {} while (0)
#endif

// --- Channel filter ---
// A list of channels (ID and name) and a mode: all channels, only the listed ones, or all but
// the listed ones. Channels are matched by ID (from the player and from each cell's data); the
// name is only used when one side has no ID.
static NSInteger gChannelMode;          // 0 all, 1 only listed, 2 all except listed
static NSArray<NSDictionary *> *gChannels;
static NSString *gVideoChannelID, *gVideoChannelName; // the main player's video
static NSString *gVideoID; // the main player's video
// The other channels of collaboration videos (video ID -> channel IDs), from the watch page's data.
static NSMutableDictionary<NSString *, NSArray<NSString *> *> *gVideoCollabs;
static NSArray<NSString *> *videoOthers(void) {
    NSMutableArray *others = [(gVideoID ? gVideoCollabs[gVideoID] : nil) mutableCopy];
    if (gVideoChannelID) [others removeObject:gVideoChannelID];
    return others;
}

// Whether a list entry is this channel: by ID when both have one (two channels can share a
// name), else by name.
static BOOL entryMatches(NSDictionary *entry, NSString *channelID, NSString *name) {
    NSString *entryID = entry[@"id"];
    if (entryID.length && channelID.length) return [entryID isEqualToString:channelID];
    return name.length && [entry[@"name"] isEqualToString:name];
}

static BOOL channelListed(NSString *channelID, NSString *name) {
    for (NSDictionary *c in gChannels) if (entryMatches(c, channelID, name)) return YES;
    return NO;
}

// The list entries for a video: its channel's, and with "Include Collaborators" those of the other
// channels of a collaboration video (others: their IDs).
static NSIndexSet *videoEntries(NSString *channelID, NSString *name, NSArray<NSString *> *others) {
    NSMutableIndexSet *found = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < gChannels.count; i++) {
        if (entryMatches(gChannels[i], channelID, name)) { [found addIndex:i]; continue; }
        if (!gCollabs) continue;
        for (NSString *other in others) if (entryMatches(gChannels[i], other, nil)) { [found addIndex:i]; break; }
    }
    return found;
}

static BOOL videoListed(NSString *channelID, NSString *name, NSArray<NSString *> *others) {
    return videoEntries(channelID, name, others).count > 0;
}

// Whether the tweak applies to a video, from its channels. A video whose channel isn't known
// counts as not listed.
static BOOL channelApplies(NSString *channelID, NSString *name, NSArray<NSString *> *others) {
    if (gChannelMode == 1) return videoListed(channelID, name, others);
    if (gChannelMode == 2) return !videoListed(channelID, name, others);
    return YES;
}

static BOOL videoApplies(void) {
    return channelApplies(gVideoChannelID, gVideoChannelName, videoOthers());
}

// The player button's choice for single videos (video ID -> hide or show), for this run of the
// app: it wins over Enabled and the channel filter for that video.
static NSMutableDictionary<NSString *, NSNumber *> *videoOverrides(void) {
    static NSMutableDictionary *d;
    if (!d) d = [NSMutableDictionary dictionary];
    return d;
}

// Whether the playing video's progress is hidden: the button's choice for it, else Enabled and
// the channel filter.
static NSNumber *videoChoice(void) {
    return gVideoID ? videoOverrides()[gVideoID] : nil;
}

static BOOL videoHides(void) {
    NSNumber *choice = videoChoice();
    return choice ? choice.boolValue : (gMaster && videoApplies());
}

static BOOL isPortrait(UIView *view);

// Whether the player bar is hidden for this player's orientation: Hide in Portrait or Hide in
// Landscape, under Enabled and the channel filter.
static BOOL enabledFor(UIView *container) {
    NSNumber *choice = videoChoice(); // the button's choice for this video wins in any orientation
    if (choice) return choice.boolValue;
    return videoHides() && (isPortrait(container) ? gEnabled : gLandscape);
}

static BOOL miniEnabled(void) {
    NSNumber *choice = videoChoice();
    if (choice) return choice.boolValue;
    return videoHides() && gMiniEnabled;
}

static id valueAt(id object, NSString *path) {
    id current = object;
    for (NSString *key in [path componentsSeparatedByString:@"."]) {
        if (!current || ![current respondsToSelector:NSSelectorFromString(key)]) return nil;
        @try { current = [current valueForKey:key]; } @catch (id e) { return nil; }
    }
    return current;
}

static void updateVideoChannel(UIViewController *player);
static UIViewController *playerFor(UIViewController *vc);
static void addLongPress(UIView *overlay, NSDictionary *buttons);

// The window's shape, not the scene's interface orientation: during a rotation (for example
// coming back from picture in picture straight into portrait) the orientation can still say
// landscape while the bar is laid out for portrait.
static BOOL isPortrait(UIView *view) {
    UIWindow *window = view.window;
    if (!window) return YES;
    return window.bounds.size.height >= window.bounds.size.width;
}

static NSHashTable<YTInlinePlayerBarContainerView *> *containers(void) {
    static NSHashTable *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [NSHashTable weakObjectsHashTable]; });
    return t;
}

// --- The bar ---
// YouTube keeps the bar (YTModularPlayerBarView) at full opacity when the controls fade, and
// sets its alpha back to 1 itself now and then. So the tweak keeps its own opacity factor per
// bar and multiplies it into every alpha YouTube sets.
//
// The factor follows the time row above the bar (the container's _peekableView: current time,
// duration, chapter). YouTube fades that row in and out with the controls, inside its own
// animation (setPeekableViewVisible: / updatePeekableViewVisibility, YouTube 20.42.3), and the
// bar's factor changes in the same animation: the bar shows exactly when the time shows (a tap,
// a paused video) and hides with it. It never touches the bar's hidden flag, which stays
// YouTube's (ads, live slates).
//
// Coming back from picture in picture while a video plays, YouTube shows only the time row, the
// bar and the fullscreen button, while the app is still in the background, and hides them 2 s later
// (animatePlayerControlsToHidden:YES with a 2 s delay). No other controls appear, so the tweak
// keeps the row hidden until that hide. A paused video gets no such hide and shows its controls.
//
// "Hide With Controls" keeps the time row and the bar hidden even while the controls show, in
// each orientation whose switch is on.

static const void *kFactorKey = &kFactorKey;      // on the bar: 0 or 1, the tweak's share
static const void *kYTAlphaKey = &kYTAlphaKey;    // on the bar: the alpha YouTube last asked for
static const void *kPeekHeldKey = &kPeekHeldKey;  // on the container: time row held hidden after PiP
static const NSTimeInterval kShowDuration = 0.2;
static const NSTimeInterval kInCurrentAnimation = -1;

static UIView *findView(UIView *v, Class cls, int depth) {
    if (!v || depth > 12) return nil;
    if ([v isKindOfClass:cls]) return v;
    for (UIView *sub in v.subviews) { UIView *r = findView(sub, cls, depth + 1); if (r) return r; }
    return nil;
}

static UIView *barViewIn(UIView *container) {
    Class barClass = objc_getClass("YTModularPlayerBarView");
    for (UIView *sub in container.subviews) if ([sub isKindOfClass:barClass]) return sub;
    return nil;
}

// A view the container keeps in an ivar. Read through the ivar, so a YouTube version without it
// gives nil, not an exception.
static UIView *partOf(UIView *container, const char *name) {
    Ivar ivar = class_getInstanceVariable([container class], name);
    id view = ivar ? object_getIvar(container, ivar) : nil;
    return [view isKindOfClass:[UIView class]] ? view : nil;
}

// The time row.
static UIView *peekOf(UIView *container) {
    return partOf(container, "_peekableView");
}

static CGFloat factorOf(UIView *bar) {
    NSNumber *f = objc_getAssociatedObject(bar, kFactorKey);
    return f ? f.doubleValue : 1;
}

// The hooked setAlpha: of each bar class: remember YouTube's alpha, apply it times the factor.
static CGFloat noteAlpha(UIView *bar, CGFloat alpha) {
    objc_setAssociatedObject(bar, kYTAlphaKey, @(alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return alpha * factorOf(bar);
}

// Sets the tweak's factor (0 or 1) on a bar whose class has the setAlpha: hook. duration
// kInCurrentAnimation joins the animation YouTube is running (or changes at once outside one);
// a positive duration runs its own fade.
static void setFactor(UIView *bar, CGFloat factor, NSTimeInterval duration) {
    if (factorOf(bar) == factor) return;
    NSNumber *yt = objc_getAssociatedObject(bar, kYTAlphaKey);
    CGFloat ytAlpha = yt ? yt.doubleValue : (factorOf(bar) > 0 ? bar.alpha : 1);
    objc_setAssociatedObject(bar, kFactorKey, @(factor), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    void (^change)(void) = ^{ bar.alpha = ytAlpha; }; // the hook applies the new factor
    if (duration == kInCurrentAnimation) {
        if ([UIView inheritedAnimationDuration] > 0) change();
        else [UIView performWithoutAnimation:change];
        return;
    }
    [UIView animateWithDuration:duration delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:change completion:nil];
}

static BOOL hideWithControls(UIView *container) {
    return enabledFor(container) && gAlways;
}

// Keeps the time row hidden while it is held after picture in picture (with the fullscreen
// button) or "Hide With Controls" is on, then gives the bar the row's visibility.
static const void *kPeekZeroedKey = &kPeekZeroedKey;     // on the container: the tweak hid the time row
static const void *kControlsShownKey = &kControlsShownKey; // on the container: YouTube shows the controls

static void syncBar(UIView *container, NSTimeInterval duration) {
    UIView *peek = peekOf(container);
    BOOL held = [objc_getAssociatedObject(container, kPeekHeldKey) boolValue];
    BOOL hidePeek = hideWithControls(container) || held;
    if (peek && peek.alpha > 0 && hidePeek) {
        peek.alpha = 0;
        objc_setAssociatedObject(container, kPeekZeroedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (peek && !hidePeek && [objc_getAssociatedObject(container, kPeekZeroedKey) boolValue]) {
        // The tweak stopped hiding it (the player button, a switch, another channel) while the
        // controls show: YouTube won't show it again until the controls next open, so do it here.
        objc_setAssociatedObject(container, kPeekZeroedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if ([objc_getAssociatedObject(container, kControlsShownKey) boolValue] && peek.alpha < 1) {
            YTHP_LOG(@"time row back with the controls");
            void (^show)(void) = ^{ peek.alpha = 1; };
            if (duration == kInCurrentAnimation) show();
            else [UIView animateWithDuration:duration delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:show completion:nil];
        }
    }
    // After picture in picture YouTube shows the fullscreen button with the row: hold it too.
    UIView *fullscreen = partOf(container, "_enterFullscreenButton");
    if (held && fullscreen.alpha > 0) fullscreen.alpha = 0;
    UIView *bar = barViewIn(container);
    if (!bar) return;
    BOOL timeShown = peek && !peek.hidden && peek.alpha > 0.01;
    CGFloat target = (enabledFor(container) && (!timeShown || gAlways)) ? 0 : 1;
    if (factorOf(bar) != target)
        YTHP_LOG(@"sync %p time=%d portrait=%d -> %.0f (anim %.2f)", container, timeShown, isPortrait(container), target, [UIView inheritedAnimationDuration]);
    setFactor(bar, target, duration);
}

// The overlay controller's bar container, found once and remembered (weakly).
static UIView *containerFor(UIViewController *overlayVC) {
    static NSMapTable<UIViewController *, UIView *> *cache;
    if (!cache) cache = [NSMapTable weakToWeakObjectsMapTable];
    UIView *container = [cache objectForKey:overlayVC];
    if (container && container.window) return container;
    container = findView(overlayVC.viewIfLoaded, objc_getClass("YTInlinePlayerBarContainerView"), 0);
    if (container) {
        [cache setObject:container forKey:overlayVC];
        [containers() addObject:(id)container];
    }
    return container;
}

static void holdPeek(UIViewController *overlayVC, BOOL hold) {
    UIView *container = containerFor(overlayVC);
    if (!container || [objc_getAssociatedObject(container, kPeekHeldKey) boolValue] == hold) return;
    YTHP_LOG(@"time row %@", hold ? @"held hidden after PiP" : @"released");
    objc_setAssociatedObject(container, kPeekHeldKey, hold ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (hold) [UIView performWithoutAnimation:^{ syncBar(container, kInCurrentAnimation); }];
}

%hook YTModularPlayerBarView
- (void)setAlpha:(CGFloat)alpha {
    %orig(noteAlpha(self, alpha));
}
%end


// A new video in the main player (the one with YouTube's main overlay, not feed previews).
%hook YTPlayerViewController
- (void)startObservingStateChangesOnActiveVideo {
    %orig;
    id overlay = valueAt(self, @"activeVideoPlayerOverlay");
    if (![overlay isKindOfClass:objc_getClass("YTMainAppVideoPlayerOverlayViewController")]) return;
    __weak UIViewController *weakSelf = (UIViewController *)self;
    updateVideoChannel(weakSelf);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ updateVideoChannel(weakSelf); });
}
%end

%hook YTMainAppVideoPlayerOverlayViewController
- (void)animatePlayerControlsToHidden:(BOOL)hidden animationDuration:(double)duration afterDelay:(double)delay withOptions:(unsigned long)options {
    YTHP_LOG(@"animateToHidden %d dur=%.2f delay=%.2f appState=%ld", hidden, duration, delay, (long)UIApplication.sharedApplication.applicationState);
    updateVideoChannel(playerFor((UIViewController *)self)); // a new video starts hidden
    %orig;
    // Back from picture in picture with the video playing: see the comment at the top.
    if (hidden && delay > 0 && UIApplication.sharedApplication.applicationState == UIApplicationStateBackground)
        holdPeek((UIViewController *)self, YES);
}
- (void)playerControlsWillHide {
    UIView *container = containerFor((UIViewController *)self);
    if (container) objc_setAssociatedObject(container, kControlsShownKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    holdPeek((UIViewController *)self, NO);
    %orig;
}
- (void)playerControlsWillShow {
    UIView *shownContainer = containerFor((UIViewController *)self);
    if (shownContainer) objc_setAssociatedObject(shownContainer, kControlsShownKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    updateVideoChannel(playerFor((UIViewController *)self));
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateBackground)
        holdPeek((UIViewController *)self, NO); // a real tap
    %orig;
}
%end

%hook YTInlinePlayerBarContainerView
- (void)setPeekableViewVisible:(BOOL)visible {
    %orig;
    syncBar(self, kInCurrentAnimation);
}
- (void)updatePeekableViewVisibility {
    %orig;
    syncBar(self, kInCurrentAnimation);
}
- (void)layoutSubviews {
    %orig;
    syncBar(self, kInCurrentAnimation); // rotation and size changes
    if ([self respondsToSelector:@selector(overlayButtons)]) addLongPress(self, [(id)self overlayButtons]);
}
- (void)didMoveToWindow {
    %orig;
    if (!self.window) return;
    [containers() addObject:self];
    syncBar(self, kInCurrentAnimation);
}
%end

// --- The miniplayer ---
// The floating miniplayer's 2 pt line along its bottom edge (YTWatchFloatingMiniplayerProgressBarView).
// It has no controls to follow: hidden whenever its option is on.

static NSHashTable<UIView *> *miniBars(void) {
    static NSHashTable *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [NSHashTable weakObjectsHashTable]; });
    return t;
}

static void applyMini(UIView *bar, NSTimeInterval duration) {
    [miniBars() addObject:bar];
    setFactor(bar, miniEnabled() ? 0 : 1, duration);
}

%hook YTWatchFloatingMiniplayerProgressBarView
- (void)setAlpha:(CGFloat)alpha {
    %orig(noteAlpha(self, alpha));
}
- (void)didMoveToWindow {
    %orig;
    if (self.window) applyMini(self, 0);
}
%end

// --- Thumbnails ---
// The red bar along the bottom of a thumbnail that shows how much of the video was watched, and
// the length badge in its corner. Two kinds of video cells (YouTube 20.42.3):
// - Elements cells (home, search, watch next, channels): the thumbnail is an _ASDisplayView with
//   the identifier eml.thumbnail. The watched bar is an unnamed subview, as wide as the
//   thumbnail, 3 pt tall, on its bottom edge; the length badge is the subview eml.timestamp.
// - Native cells (history, playlists, downloads): a YTProgressView next to the thumbnail view
//   (id.ui.video.thumbnail.view), and a YTBadge with the identifier id.time.status.overlay.badge.
// The tweak hides what it finds and remembers it, so switching an option off shows it again.

@interface _ASDisplayView : UIView
@end
@interface YTBadge : UIView
@end
@interface YTProgressView : UIView
@end

static const void *kThumbHiddenKey = &kThumbHiddenKey; // on a view the tweak hid

static BOOL watchedOn(void) { return gMaster && gWatched; }
static BOOL lengthOn(void) { return gMaster && gLength; }

static BOOL looksLikeDuration(NSString *s) {
    return [s rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet].location != NSNotFound
        && ([s containsString:@"second"] || [s containsString:@"minute"] || [s containsString:@"hour"]);
}

// The channel name in a video cell's label: "Title - 16 minutes, 34 seconds - Go to channel X -
// X - 3.8 million views - 11 days ago - play video", or in history and playlists "Title - 14
// minutes, 10 seconds -  - X - play video".
static NSString *channelFromLabel(NSString *label) {
    // Playlists: "Title, Channel, 207K views ,  1 year ago".
    NSRange views = [label rangeOfString:@" views , " options:NSBackwardsSearch];
    if (views.location != NSNotFound && ![label containsString:@" - play video"]) {
        // The length, when shown, comes before the view count ("Kris, 15 minutes, 1 second, 207K").
        NSArray<NSString *> *items = [[label substringToIndex:views.location] componentsSeparatedByString:@", "];
        for (NSInteger j = (NSInteger)items.count - 2; j >= 1; j--) {
            NSString *item = [items[j] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (item.length && !looksLikeDuration(item)) return item;
        }
        return nil;
    }
    NSArray<NSString *> *parts = [label componentsSeparatedByString:@" - "];
    for (NSString *part in parts)
        if ([part hasPrefix:@"Go to channel "]) return [part substringFromIndex:14];
    for (NSUInteger i = 1; i < parts.count; i++) {
        NSString *part = parts[i];
        if (!([part hasSuffix:@" views"] || [part hasSuffix:@" view"] || [part hasSuffix:@" watching"] || [part isEqualToString:@"play video"])) continue;
        for (NSInteger j = (NSInteger)i - 1; j >= 1; j--) {
            NSString *q = [parts[j] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (q.length && !looksLikeDuration(q) && ![@[@"Live", @"LIVE", @"Upcoming", @"Premiere", @"New", @"Members only"] containsObject:q]) return q;
        }
        return nil;
    }
    return nil;
}

static BOOL isVideoLabel(NSString *label) {
    return [label hasSuffix:@" - play video"] || [label containsString:@" - Go to channel "] || [label containsString:@" views , "];
}

// Text-format strings escape bytes outside ASCII as octal ("\303\251" for "é") and quotes and
// backslashes with a backslash.
static NSString *unescapeProtoText(NSString *s) {
    NSMutableData *bytes = [NSMutableData data];
    const char *c = s.UTF8String;
    for (size_t i = 0; c && c[i]; i++) {
        unsigned char out = (unsigned char)c[i];
        if (c[i] == '\\' && c[i + 1]) {
            if (c[i + 1] >= '0' && c[i + 1] <= '7' && c[i + 2] >= '0' && c[i + 2] <= '7' && c[i + 3] >= '0' && c[i + 3] <= '7') {
                out = (unsigned char)((c[i + 1] - '0') * 64 + (c[i + 2] - '0') * 8 + (c[i + 3] - '0'));
                i += 3;
            } else {
                out = (unsigned char)c[++i];
                if (out == 'n') out = '\n';
            }
        }
        [bytes appendBytes:&out length:1];
    }
    return [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
}

// The channel in a playlist or history renderer, from its fields: the byline's first run, whose
// link is the channel (short_byline_text { runs { text, navigation_endpoint { browse_endpoint
// { browse_id } } } }; browse_endpoint is an extension of the endpoint message).
// An extension of an endpoint message, such as YTIBrowseEndpointRoot's browseEndpoint.
static id endpointExtension(id endpoint, const char *rootClass, SEL field) {
    Class root = objc_getClass(rootClass);
    id extension = [root respondsToSelector:field] ? ((id (*)(id, SEL))objc_msgSend)(root, field) : nil;
    return extension && [endpoint respondsToSelector:@selector(getExtension:)] ? [endpoint performSelector:@selector(getExtension:) withObject:extension] : nil;
}

static NSArray *channelFromFields(id entry) {
    id runs = valueAt(entry, @"shortBylineText.runsArray");
    if (![runs isKindOfClass:[NSArray class]]) return nil;
    // Every run that links a channel: the first is the video's, any others a collaboration's.
    NSString *channelID = nil, *name = nil;
    NSMutableOrderedSet *others = [NSMutableOrderedSet orderedSet];
    for (id run in runs) {
        id browse = endpointExtension(valueAt(run, @"navigationEndpoint"), "YTIBrowseEndpointRoot", @selector(browseEndpoint));
        NSString *runID = valueAt(browse, @"browseId");
        if (![runID isKindOfClass:[NSString class]] || ![runID hasPrefix:@"UC"]) continue;
        if (!channelID) { channelID = runID; name = valueAt(run, @"text"); }
        else if (![runID isEqualToString:channelID]) [others addObject:runID];
    }
    if (!channelID) return nil;
    return @[channelID, [name isKindOfClass:[NSString class]] ? name : @"", others.array];
}

// The IDs of every channel a renderer's text form links to (browse endpoints: browse_id is field
// 2, "\022\030UC…"), in order, without excluded.
static NSArray<NSString *> *linkedChannels(NSString *text, NSString *excluded) {
    static NSRegularExpression *browseID;
    if (!browseID) browseID = [NSRegularExpression regularExpressionWithPattern:@"\\\\022\\\\030(UC[A-Za-z0-9_-]{22})" options:0 error:nil];
    NSMutableOrderedSet *ids = [NSMutableOrderedSet orderedSet];
    for (NSTextCheckingResult *hit in [browseID matchesInString:text options:0 range:NSMakeRange(0, text.length)])
        [ids addObject:[text substringWithRange:[hit rangeAtIndex:1]]];
    if (excluded) [ids removeObject:excluded];
    return ids.array;
}

// What collaboration data says about each of its channels (ID -> name, picture URL): each channel
// is a list item ("list_item.eml") with its name as the first text field (a length, then that
// many bytes) and its picture's URL, before or after its link.
static NSMutableDictionary<NSString *, NSDictionary *> *gChannelInfo;

// The text of length bytes at i, in text-format escaping; nil unless it ends right there.
static NSString *textOfLength(NSString *text, NSUInteger i, NSUInteger length, NSUInteger *end) {
    NSMutableData *bytes = [NSMutableData data];
    while (bytes.length < length && i < text.length) {
        unichar c = [text characterAtIndex:i];
        unsigned char out;
        if (c == '\\' && i + 1 < text.length) {
            unichar d = [text characterAtIndex:i + 1];
            if (d >= '0' && d <= '7' && i + 3 < text.length) {
                out = (unsigned char)((d - '0') * 64 + ([text characterAtIndex:i + 2] - '0') * 8 + ([text characterAtIndex:i + 3] - '0'));
                i += 4;
            } else {
                out = d == 'n' ? '\n' : d == 't' ? '\t' : d == 'r' ? '\r' : (unsigned char)d;
                i += 2;
            }
        } else if (c < 0x80) {
            out = (unsigned char)c;
            i++;
        } else return nil;
        [bytes appendBytes:&out length:1];
    }
    if (bytes.length != length) return nil;
    if (end) *end = i;
    return [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
}

static void loadPicture(NSString *channelID, void (^done)(UIImage *picture));
static void learnChannels(NSString *text, NSArray<NSString *> *channelIDs) {
    static NSRegularExpression *field, *picture;
    if (!field) field = [NSRegularExpression regularExpressionWithPattern:@"\\\\n(\\\\[0-7]{3}|[^\\\\])" options:0 error:nil];
    if (!picture) picture = [NSRegularExpression regularExpressionWithPattern:@"https://yt3\\.ggpht\\.com/[^\\\\\"]+" options:0 error:nil];
    if (!gChannelInfo) gChannelInfo = [NSMutableDictionary dictionary];
    for (NSString *channelID in channelIDs) {
        NSRange link = [text rangeOfString:[@"\\022\\030" stringByAppendingString:channelID]];
        if (link.location == NSNotFound) continue;
        NSRange item = [text rangeOfString:@"list_item.eml" options:NSBackwardsSearch range:NSMakeRange(0, link.location)];
        if (item.location == NSNotFound) continue;
        NSRange nextItem = [text rangeOfString:@"list_item.eml" options:0 range:NSMakeRange(NSMaxRange(link), text.length - NSMaxRange(link))];
        NSUInteger itemEnd = nextItem.location == NSNotFound ? text.length : nextItem.location;
        NSString *name = nil;
        for (NSTextCheckingResult *hit in [field matchesInString:text options:0 range:NSMakeRange(item.location, link.location - item.location)]) {
            NSString *len = [text substringWithRange:[hit rangeAtIndex:1]];
            NSUInteger length = len.length == 4 ? (NSUInteger)(([len characterAtIndex:1] - '0') * 64 + ([len characterAtIndex:2] - '0') * 8 + ([len characterAtIndex:3] - '0')) : [len characterAtIndex:0];
            if (!length || length > 200) continue;
            NSUInteger end = 0;
            NSString *candidate = textOfLength(text, NSMaxRange(hit.range), length, &end);
            // A text field is followed by the next field's tag ('2' or '*' here), and starts with text.
            if (!candidate.length || end >= text.length || [candidate characterAtIndex:0] < 0x20) continue;
            unichar next = [text characterAtIndex:end];
            if (next != '2' && next != '*') continue;
            name = candidate;
            break;
        }
        NSTextCheckingResult *pic = [picture firstMatchInString:text options:0 range:NSMakeRange(item.location, itemEnd - item.location)];
        NSMutableDictionary *info = [gChannelInfo[channelID] mutableCopy] ?: [NSMutableDictionary dictionary];
        if (name) info[@"name"] = name;
        if (pic) info[@"picture"] = [text substringWithRange:pic.range];
        gChannelInfo[channelID] = info;
        if (pic) loadPicture(channelID, nil); // ready for the picker
    }
}

// The channel's ID and name in a cell's data (see cellChannel), worked out once per renderer.
// Fields where they're known (playlists, history); else the message's text form: Elements data
// is mostly binary, where the channel's link is its ID followed by its handle URL
// ("UC…\"\031/@Handle"), whatever the language. Last resorts: the ID after the English channel
// button text, then the first ID. Third: the IDs of a collaboration video's other channels.
static NSArray *channelFromEntry(id entry) {
    static NSMapTable *cache;
    if (!cache) cache = [NSMapTable weakToStrongObjectsMapTable];
    NSArray *cached = [cache objectForKey:entry];
    if (cached) return cached;
    NSArray *result = channelFromFields(entry);
    NSString *text = result ? nil : [entry description];
    if ([text isKindOfClass:[NSString class]]) {
        static NSRegularExpression *withHandle, *anyID;
        if (!withHandle) withHandle = [NSRegularExpression regularExpressionWithPattern:@"(UC[A-Za-z0-9_-]{22})\\\\\"(?:\\\\[0-7]{3}|\\\\.|.)/@" options:0 error:nil];
        if (!anyID) anyID = [NSRegularExpression regularExpressionWithPattern:@"UC[A-Za-z0-9_-]{22}" options:0 error:nil];
        NSRange all = NSMakeRange(0, text.length);
        NSRange idRange = [withHandle firstMatchInString:text options:0 range:all] ? [[withHandle firstMatchInString:text options:0 range:all] rangeAtIndex:1] : NSMakeRange(NSNotFound, 0);
        if (idRange.location == NSNotFound) {
            NSRange button = [text rangeOfString:@"Go to channel "];
            NSRange from = button.location != NSNotFound ? NSMakeRange(button.location, text.length - button.location) : all;
            NSTextCheckingResult *hit = [anyID firstMatchInString:text options:0 range:from] ?: [anyID firstMatchInString:text options:0 range:all];
            if (hit) idRange = hit.range;
        }
        NSString *channelID = nil, *name = nil;
        if (idRange.location != NSNotFound) {
            channelID = [text substringWithRange:idRange];
            NSUInteger start = idRange.location > 2000 ? idRange.location - 2000 : 0;
            NSRange before = NSMakeRange(start, idRange.location - start);
            // Only renderers spelled out as fields have the name as text.
            NSRange textKey = [entry isKindOfClass:objc_getClass("YTIElementRenderer")] ? NSMakeRange(NSNotFound, 0)
                : [text rangeOfString:@"text: \"" options:NSBackwardsSearch range:before];
            if (textKey.location != NSNotFound) {
                NSUInteger nameStart = NSMaxRange(textKey), end = nameStart;
                while (end < idRange.location && !([text characterAtIndex:end] == '"' && [text characterAtIndex:end - 1] != '\\')) end++;
                if (end > nameStart && end < idRange.location) name = unescapeProtoText([text substringWithRange:NSMakeRange(nameStart, end - nameStart)]);
            }
        }
        // A collaboration video lists each channel (its link, after its handle in a "@Handle"
        // run set apart by isolate marks): every other channel linked, and the handle as the
        // name, since the cell's label joins the names.
        NSArray *others = channelID ? linkedChannels(text, channelID) : @[];
        if (others.count) {
            learnChannels(text, [@[channelID] arrayByAddingObjectsFromArray:others]);
            if (!name.length) name = gChannelInfo[channelID][@"name"];
        }
        if (others.count && !name.length) {
            static NSRegularExpression *handle;
            if (!handle) handle = [NSRegularExpression regularExpressionWithPattern:@"\\\\342\\\\201\\\\250(@[^\"\\\\]+)\\\\342\\\\201\\\\251" options:0 error:nil];
            NSTextCheckingResult *last = [handle matchesInString:text options:0 range:NSMakeRange(0, idRange.location)].lastObject;
            if (last) name = unescapeProtoText([text substringWithRange:[last rangeAtIndex:1]]);
        }
        result = @[channelID ?: @"", name ?: @"", others];
    }
    if (!result) result = @[@"", @"", @[]];
#ifdef YTHP_DEBUG
    YTHP_LOG(@"entry %@ channel %@ name %@ others %@ (%@)", [entry class], result[0], result[1], [result[2] componentsJoinedByString:@","], text ? @"text" : @"fields");
#endif
    [cache setObject:result forKey:entry];
    return result;
}

// The channel from the nearest cell with data: playlist and history cells have a renderer
// (entry); Elements cells (home, search, watch next) keep their YTIElementRenderer on the cell
// controller (the cell node's _parentResponder). videoNode: whether that cell is a video
// (YTVideoWithContextNode and the like), not a comment or a post.
static NSArray *cellChannel(UIView *view, BOOL *videoNode) {
    UIView *v = view;
    for (int depth = 0; v && depth < 14; depth++, v = v.superview) {
        // UIKit cells with their data (history, playlists: YTPlaylistVideoCell's YTIPlaylistVideoRenderer).
        if ([v isKindOfClass:[UICollectionViewCell class]] && [v respondsToSelector:@selector(entry)]) {
            id entry = [v valueForKey:@"entry"];
            if ([NSStringFromClass([entry class]) hasPrefix:@"YTI"]) {
                if (videoNode) *videoNode = [NSStringFromClass(v.class) containsString:@"Video"];
                return channelFromEntry(entry);
            }
        }
        if (![v respondsToSelector:NSSelectorFromString(@"asyncdisplaykit_node")]) continue;
        id node = [v valueForKey:@"asyncdisplaykit_node"];
        Ivar parent = node ? class_getInstanceVariable(object_getClass(node), "_parentResponder") : NULL;
        id cellController = parent ? object_getIvar(node, parent) : nil;
        if (![cellController respondsToSelector:@selector(entry)]) continue;
        if (videoNode) *videoNode = [NSStringFromClass([node class]) containsString:@"Video"];
        return channelFromEntry([cellController valueForKey:@"entry"]);
    }
    return @[@"", @"", @[]];
}

// The video cell a view is in: YES with what's known of its channel (the ID from the cell's
// data, the name from its label, a collaboration video's other channels), or NO when the view
// isn't in a video cell.
static BOOL videoCellChannel(UIView *view, NSString **name, NSString **channelID, NSArray<NSString *> **others) {
    NSString *foundName = nil;
    BOOL inCell = NO;
    UIView *v = view;
    for (int depth = 0; v && depth < 12; depth++, v = v.superview) {
        NSString *label = v.accessibilityLabel;
        if (!isVideoLabel(label)) continue;
        foundName = channelFromLabel(label);
        inCell = YES;
        break;
    }
    BOOL videoNode = NO;
    NSArray *data = cellChannel(view, &videoNode);
    NSString *foundID = [data[0] length] ? data[0] : nil;
    NSArray<NSString *> *foundOthers = data[2];
    // A collaboration video's label names every channel together: the data's name instead.
    if ((!foundName.length || foundOthers.count) && [data[1] length]) foundName = data[1];
    if (name) *name = foundName;
    if (channelID) *channelID = foundID;
    if (others) *others = foundOthers;
    return inCell || (foundID && videoNode);
}

// Thumbnail options for the cell a view is in, with the channel filter.
static void completeChannel(NSString *channelID, NSString *name, UIView *within);
static BOOL gMissingAvatars; // a listed channel has no picture, ID or name yet
static const void *kCompleteTriedKey = &kCompleteTriedKey; // on a cell: the channel already looked for

static BOOL thumbApplies(UIView *view) {
    if (gChannelMode == 0) return YES;
    NSString *name = nil, *channelID = nil;
    NSArray<NSString *> *others = nil;
    videoCellChannel(view, &name, &channelID, &others);
    // A listed channel without a picture or ID: take them from this cell once it's on screen.
    if (gMissingAvatars && (name || channelID) && channelListed(channelID, name)) {
        UIView *cell = view;
        while (cell && !isVideoLabel(cell.accessibilityLabel) && ![cell isKindOfClass:[UICollectionViewCell class]]) cell = cell.superview;
        cell = cell ?: view;
        // Once per cell and channel: a cell's parts lay out many times.
        NSString *tried = [NSString stringWithFormat:@"%@|%@", channelID, name];
        if (![objc_getAssociatedObject(cell, kCompleteTriedKey) isEqualToString:tried]) {
            objc_setAssociatedObject(cell, kCompleteTriedKey, tried, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            __weak UIView *weakCell = cell;
            dispatch_async(dispatch_get_main_queue(), ^{ if (weakCell.window) completeChannel(channelID, name, weakCell); });
        }
    }
    return channelApplies(channelID, name, others);
}

static void setThumbPartHidden(UIView *view, BOOL hide) {
    BOOL ours = [objc_getAssociatedObject(view, kThumbHiddenKey) boolValue];
    if (hide && !view.hidden) {
        view.hidden = YES;
        objc_setAssociatedObject(view, kThumbHiddenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (!hide && ours) {
        view.hidden = NO;
        objc_setAssociatedObject(view, kThumbHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Native cells size a hidden part to nothing (the watched bar is 0 pt tall): lay out again.
        [view.superview setNeedsLayout];
        [view.superview.superview setNeedsLayout];
    }
}

// The same badge spot shows "LIVE", "Upcoming" and the like; only a length (read out as, for
// example, "19 minutes, 49 seconds") has digits.
static BOOL isLengthBadge(UIView *badge) {
    NSString *label = badge.accessibilityLabel;
    return label && [label rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet].location != NSNotFound;
}

static BOOL isElementsWatchedBar(UIView *bar, UIView *thumb) {
    CGRect f = bar.frame, t = thumb.bounds;
    return f.size.height > 0 && f.size.height <= 4 && f.size.width >= t.size.width * 0.9 && fabs(CGRectGetMaxY(f) - CGRectGetMaxY(t)) <= 1.5 && !bar.accessibilityIdentifier.length;
}

static void applyElementsThumb(UIView *thumb) {
    BOOL applies = (lengthOn() || watchedOn()) && thumbApplies(thumb);
    for (UIView *sub in thumb.subviews) {
        if ([sub.accessibilityIdentifier isEqualToString:@"eml.timestamp"]) setThumbPartHidden(sub, applies && lengthOn() && isLengthBadge(sub));
        else if (isElementsWatchedBar(sub, thumb) || [objc_getAssociatedObject(sub, kThumbHiddenKey) boolValue]) setThumbPartHidden(sub, applies && watchedOn());
    }
}

static BOOL besideThumbnail(UIView *view) {
    for (UIView *sibling in view.superview.subviews)
        if ([sibling.accessibilityIdentifier isEqualToString:@"id.ui.video.thumbnail.view"]) return YES;
    return NO;
}

static void applyThumbView(UIView *view) {
    if ([view isKindOfClass:objc_getClass("_ASDisplayView")]) {
        if ([view.accessibilityIdentifier isEqualToString:@"eml.thumbnail"]) applyElementsThumb(view);
    } else if ([view isKindOfClass:objc_getClass("YTBadge")]) {
        if ([view.accessibilityIdentifier isEqualToString:@"id.time.status.overlay.badge"]) setThumbPartHidden(view, lengthOn() && isLengthBadge(view) && thumbApplies(view));
    } else if ([view isKindOfClass:objc_getClass("YTProgressView")]) {
        if (besideThumbnail(view)) setThumbPartHidden(view, watchedOn() && thumbApplies(view));
    }
}

%hook _ASDisplayView
- (void)layoutSubviews {
    %orig;
    applyThumbView(self);
}
- (void)didMoveToWindow {
    %orig;
    if (self.window) applyThumbView(self); // back on screen, for example another tab's feed
}
%end

// Who hid a thumbnail part: the tweak (so it may show it again when an option or the channel
// list changes) or YouTube (left alone).
static void noteThumbHide(UIView *view, BOOL youTubeHid, BOOL tweakHid) {
    if (tweakHid) objc_setAssociatedObject(view, kThumbHiddenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    else if (youTubeHid) objc_setAssociatedObject(view, kThumbHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%hook YTBadge
- (void)layoutSubviews {
    %orig;
    applyThumbView(self);
}
- (void)didMoveToWindow {
    %orig;
    if (self.window) applyThumbView(self);
}
- (void)setHidden:(BOOL)hidden {
    // YouTube shows the badge again when a cell is reused: keep it hidden while the option is on.
    BOOL keep = !hidden && lengthOn() && [self.accessibilityIdentifier isEqualToString:@"id.time.status.overlay.badge"] && isLengthBadge(self) && thumbApplies(self);
    %orig(hidden || keep);
    noteThumbHide(self, hidden, keep);
}
%end

%hook YTProgressView
- (void)layoutSubviews {
    %orig;
    applyThumbView(self);
}
- (void)setHidden:(BOOL)hidden {
    // YouTube shows it again when the cell's watch progress arrives: keep it hidden while the option is on.
    BOOL keep = !hidden && watchedOn() && besideThumbnail(self) && thumbApplies(self);
    %orig(hidden || keep);
    noteThumbHide(self, hidden, keep);
}
- (void)didMoveToWindow {
    %orig;
    if (self.window) applyThumbView(self);
}
%end

static void applyThumbsIn(UIView *view) {
    applyThumbView(view);
    for (UIView *sub in view.subviews) applyThumbsIn(sub);
}

static void refreshAll(void) {
    // With "Hide With Controls" switched off, a time row held at 0 comes back with the next controls.
    for (YTInlinePlayerBarContainerView *c in containers().allObjects) syncBar(c, kShowDuration);
    for (UIView *bar in miniBars().allObjects) applyMini(bar, kShowDuration);
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:[UIWindowScene class]])
            for (UIWindow *window in ((UIWindowScene *)scene).windows) applyThumbsIn(window);
}

// --- The player button (YTVideoOverlay) ---
// Hides or shows the playing video's progress, for that video. The icon is crossed out while
// the video's bar is hidden.

#define kOverlayTweakID @"YTHideProgress"

// The tweak's icon: a progress bar, a thin line with a large dot. Slashed: the bar is hidden.
// A template image (it takes the tint), size x size points.
static UIImage *tweakIcon(CGFloat size, BOOL slashed) {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size)];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGFloat mid = size / 2, line = MAX(1.5, size * 0.085);
        [UIColor.blackColor setFill];
        [UIColor.blackColor setStroke];
        UIBezierPath *track = [UIBezierPath bezierPath];
        [track moveToPoint:CGPointMake(size * 0.1, mid)];
        [track addLineToPoint:CGPointMake(size * 0.9, mid)];
        track.lineWidth = line;
        track.lineCapStyle = kCGLineCapRound;
        [track stroke];
        CGFloat r = size * 0.18; // the dot near the start, so a slash can cross the line beside it
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(size * 0.28 - r, mid - r, 2 * r, 2 * r)] fill];
        if (!slashed) return;
        UIBezierPath *slash = [UIBezierPath bezierPath];
        [slash moveToPoint:CGPointMake(size * 0.5, size * 0.12)];
        [slash addLineToPoint:CGPointMake(size * 0.9, size * 0.88)];
        slash.lineCapStyle = kCGLineCapRound;
        CGContextSetBlendMode(c, kCGBlendModeClear); // a gap around the slash
        slash.lineWidth = line * 2.2;
        [slash stroke];
        CGContextSetBlendMode(c, kCGBlendModeNormal);
        slash.lineWidth = line;
        [slash stroke];
    }];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static UIImage *buttonImage(void) {
    return [tweakIcon(24, videoHides()) imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
}

// The lock screen player is drawn by MediaRemoteUI, whose sandbox can't read YouTube's settings,
// so the switch it needs is published as a notify state (bit 1: set, bit 2: hide in now playing).
// Bits 4 (System Players as loaded) and 8 (jailbreak part installed) are SpringBoard's and kept.
#define kStateName "com.goldenappleguy.ythideprogress.state"
#define kRespringName "com.goldenappleguy.ythideprogress.respring"
// The registration is kept: notifyd forgets a state nobody is registered for.
static int stateToken(void) {
    static int token = -1;
    if (token == -1 && notify_register_check(kStateName, &token) != NOTIFY_STATUS_OK) token = -1;
    return token;
}

static uint64_t sharedState(void) {
    uint64_t state = 0;
    if (stateToken() != -1) notify_get_state(stateToken(), &state);
    return state;
}

static void publishState(void) {
    int token = stateToken();
    if (token == -1) return;
    uint64_t old = sharedState();
    id lock = [[NSUserDefaults standardUserDefaults] objectForKey:kLockKey];
    BOOL lockOn = (lock ? [lock boolValue] : YES) && videoHides();
    // Bit 16: the channel filter leaves the current video out (picture in picture).
    notify_set_state(token, (old & 44) | 1 | (lockOn ? 2 : 0) | (videoHides() ? 0 : 16)); // 4, 8, 32: SpringBoard's
    notify_post(kStateName);
}

// System Players takes effect when SpringBoard starts. Its value is shared at once (the
// preferences file may not be written yet), so any later respring uses it; then the respring
// is offered.
static void shareSystemPlayers(BOOL on) {
    static int token = -1; // kept: notifyd forgets a state nobody is registered for
    if (token == -1 && notify_register_check(kRespringName, &token) != NOTIFY_STATUS_OK) { token = -1; return; }
    notify_set_state(token, on ? 2 : 1);
}

static void askToRespring(UIViewController *vc) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Respring Required"
        message:@"System Players changes take effect after a respring."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Respring Later" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Respring Now" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        notify_post(kRespringName);
    }]];
    UIViewController *top = vc;
    while (top.presentedViewController) top = top.presentedViewController;
    YTHP_LOG(@"ask, top=%@", top);
    if ([top isKindOfClass:[UIAlertController class]]) return; // already asking
    [top presentViewController:alert animated:YES completion:nil];
}

static void setMaster(BOOL on) {
    gMaster = on;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kMasterKey];
    publishState();
    refreshAll();
}

// YouTube's toast walks its own responder chain (parentResponder), which the overlay views are
// not part of: start from the nearest responder above the view that is.
static void showToast(UIResponder *from, NSString *message) {
    Class toast = objc_getClass("YTToastResponderEvent");
    if (![toast respondsToSelector:@selector(eventWithMessage:firstResponder:)]) return;
    for (UIResponder *r = from; r; r = r.nextResponder) {
        if (![r respondsToSelector:NSSelectorFromString(@"parentResponder")]) continue;
        [[toast eventWithMessage:message firstResponder:r] send];
        return;
    }
}

// The button hides or shows the playing video's progress, for that video only.
static void buttonPressed(UIView *overlay, NSDictionary <NSString *, YTQTMButton *> *buttons) {
    UIViewController *player = nil;
    for (UIResponder *r = overlay; r && !player; r = r.nextResponder)
        if ([r isKindOfClass:[UIViewController class]]) player = playerFor((UIViewController *)r);
    if (player) updateVideoChannel(player);
    if (!gVideoID) return;
    BOOL hide = !videoHides();
    videoOverrides()[gVideoID] = @(hide);
    publishState();
    refreshAll();
    [buttons[kOverlayTweakID] setImage:buttonImage() forState:UIControlStateNormal];
    showToast(overlay, hide ? @"Progress hidden for this video" : @"Progress shown for this video");
}

// --- Channel list: the player's video, adding and removing ---


// The channel of the video in a YTPlayerViewController (YouTube 20.42.3:
// playerResponse.playerData.videoDetails.channelId / author).
static void updateVideoChannel(UIViewController *player) {
    if (![player isKindOfClass:objc_getClass("YTPlayerViewController")]) return;
    id details = valueAt(player, @"playerResponse.playerData.videoDetails");
    NSString *channelID = valueAt(details, @"channelId"), *name = valueAt(details, @"author"), *videoID = valueAt(details, @"videoId");
    if (![channelID isKindOfClass:[NSString class]] || !channelID.length) return; // not loaded yet
    if (![videoID isKindOfClass:[NSString class]]) videoID = nil;
    if ([channelID isEqualToString:gVideoChannelID] && (!videoID || [videoID isEqualToString:gVideoID])) return;
    BOOL hidBefore = videoHides();
    gVideoChannelID = [channelID copy];
    gVideoChannelName = [name isKindOfClass:[NSString class]] ? [name copy] : nil;
    gVideoID = [videoID copy];
    YTHP_LOG(@"video %@ channel %@ (%@) hides=%d", gVideoID, gVideoChannelName, gVideoChannelID, videoHides());
    if (gMissingAvatars) completeChannel(gVideoChannelID, gVideoChannelName, nil); // a listed channel's missing name
    if (videoHides() != hidBefore) refreshAll();
    publishState();
}

// A collaboration video's channels, from the watch page's data (YouTube 20.42.3: the player
// overlay's heading, an Elements renderer that links each channel). It can come before or after
// the player's own details.
static void noteWatchNextResponse(id response) {
    id watch = endpointExtension(valueAt(response, @"currentVideoEndpoint"), "YTIWatchEndpointRoot", @selector(watchEndpoint));
    NSString *videoID = valueAt(watch, @"videoId");
    id heading = valueAt(response, @"playerOverlays.playerOverlayRenderer.videoDetails.elementRenderer");
    if (![videoID isKindOfClass:[NSString class]] || !videoID.length || !heading) return;
    NSString *text = [heading description];
    NSArray<NSString *> *channels = linkedChannels(text, nil);
    YTHP_LOG(@"watch next %@ channels %@", videoID, [channels componentsJoinedByString:@","]);
    if (!gVideoCollabs) gVideoCollabs = [NSMutableDictionary dictionary];
    BOOL hidBefore = videoHides();
    gVideoCollabs[videoID] = channels.count > 1 ? channels : nil;
    if (channels.count > 1) learnChannels(text, channels);
    if (![videoID isEqualToString:gVideoID] || videoHides() == hidBefore) return;
    refreshAll();
    publishState();
}

%hook YTWatchNextViewController
- (void)loadWithResponse:(id)response {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ noteWatchNextResponse(response); });
}
%end

static UIViewController *playerFor(UIViewController *vc) {
    for (UIViewController *v = vc; v; v = v.parentViewController)
        if ([v isKindOfClass:objc_getClass("YTPlayerViewController")]) return v;
    return nil;
}

static void noteMissingAvatars(void) {
    gMissingAvatars = NO;
    // A "@Handle" name (from a collaboration video's cell) waits for the channel's own name.
    for (NSDictionary *c in gChannels) if (!c[@"avatar"] || !c[@"id"] || ![c[@"name"] length] || [c[@"name"] hasPrefix:@"@"]) gMissingAvatars = YES;
}

static void saveChannels(NSArray *channels) {
    gChannels = [channels copy];
    noteMissingAvatars();
    [[NSUserDefaults standardUserDefaults] setObject:gChannels forKey:kChannelsKey];
    refreshAll();
    publishState();
}

// The channel's picture, from a view on screen that shows it: a feed cell's "Go to channel X"
// avatar, or the watch page's channel button ("X 21.4M subscribers").
static UIView *findAvatarView(UIView *root, NSString *name, int depth) {
    if (!root || root.hidden || depth > 60) return nil;
    NSString *label = root.accessibilityLabel;
    CGSize size = root.bounds.size;
    if (label && size.width >= 20 && size.width <= 64 && size.height >= 20
        && ((name && [label isEqualToString:[@"Go to channel " stringByAppendingString:name]])
            || ([label hasSuffix:@"subscribers"] && (!name || [label hasPrefix:name]))))
        return root;
    for (UIView *sub in root.subviews) {
        UIView *found = findAvatarView(sub, name, depth + 1);
        if (found) return found;
    }
    return nil;
}

// In a feed cell, the avatar for that channel's name. In the whole window (the watch page,
// which has one channel button), any channel button: its label can differ from the channel's
// name ("Radiohead, Official Artist Channel" for "Radiohead - Topic").
static NSData *avatarIn(UIView *within, NSString *name) {
    if (!within || !name.length) return nil;
    UIView *v = findAvatarView(within, [within isKindOfClass:[UIWindow class]] ? nil : name, 0);
    if (!v) return nil;
    CGSize b = v.bounds.size;
    CGFloat side = MIN(b.width, b.height), out = 40, k = out / side;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 2;
    UIImage *image = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(out, out) format:format] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [v drawViewHierarchyInRect:CGRectMake(-(b.width - side) / 2 * k, -(b.height - side) / 2 * k, b.width * k, b.height * k) afterScreenUpdates:NO];
    }];
    return UIImagePNGRepresentation(image);
}

static UIWindow *keyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:[UIWindowScene class]])
            for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) return w;
    return UIApplication.sharedApplication.windows.firstObject;
}

static NSInteger channelIndex(NSString *channelID, NSString *name) {
    for (NSUInteger i = 0; i < gChannels.count; i++) {
        if (entryMatches(gChannels[i], channelID, name)) return (NSInteger)i;
    }
    return NSNotFound;
}

// Whether the video would have its progress hidden after toggling its channels (toggleChannel).
static BOOL hiddenAfterToggle(NSString *channelID, NSString *name, NSArray<NSString *> *others) {
    BOOL listedAfter = gChannelMode == 0 ? !channelListed(channelID, name) : !videoListed(channelID, name, others);
    return gChannelMode == 1 ? listedAfter : gChannelMode == 2 ? !listedAfter : YES;
}

// Fills in a listed channel's missing picture or ID when the channel is on screen.
static void fetchPicture(NSString *channelID);
static void completeChannel(NSString *channelID, NSString *name, UIView *within) {
    NSInteger i = channelIndex(channelID, name);
    if (i == NSNotFound) return;
    NSMutableDictionary *entry = [gChannels[i] mutableCopy];
    BOOL changed = NO;
    NSString *known = entry[@"id"] ? gChannelInfo[entry[@"id"]][@"name"] : nil;
    if ((!name.length || [name hasPrefix:@"@"]) && known.length) name = known;
    if (!entry[@"avatar"]) {
        NSData *avatar = avatarIn(within, entry[@"name"]);
        if (avatar) { entry[@"avatar"] = avatar; changed = YES; }
        else fetchPicture(entry[@"id"]);
    }
    if (!entry[@"id"] && channelID.length) { entry[@"id"] = channelID; changed = YES; }
    if ((![entry[@"name"] length] || [entry[@"name"] hasPrefix:@"@"]) && name.length && ![name hasPrefix:@"@"] && ![entry[@"name"] isEqualToString:name]) { entry[@"name"] = name; changed = YES; }
    if (!changed) return;
    NSMutableArray *list = [gChannels mutableCopy];
    list[i] = entry;
    gChannels = [list copy];
    noteMissingAvatars();
    [[NSUserDefaults standardUserDefaults] setObject:gChannels forKey:kChannelsKey];
}

// Downloads a listed channel's picture from the URL in collaboration data (gChannelInfo), for a
// channel whose picture isn't on screen (a collaboration video shows them stacked).
static NSMutableDictionary<NSString *, UIImage *> *gPictures; // channel ID -> picture (40 pt)

// Downloads a channel's picture from the URL in collaboration data (gChannelInfo), once.
static void loadPicture(NSString *channelID, void (^done)(UIImage *picture)) {
    static NSMutableDictionary<NSString *, NSMutableArray *> *waiting;
    if (!gPictures) gPictures = [NSMutableDictionary dictionary];
    if (!waiting) waiting = [NSMutableDictionary dictionary];
    UIImage *cached = channelID ? gPictures[channelID] : nil;
    if (cached) { if (done) done(cached); return; }
    NSString *url = channelID ? gChannelInfo[channelID][@"picture"] : nil;
    if (!url) return;
    BOOL started = waiting[channelID] != nil;
    if (!started) waiting[channelID] = [NSMutableArray array];
    if (done) [waiting[channelID] addObject:[done copy]];
    if (started) return;
    // The URL ends in its size ("=s88-c-…"): ask for the size the list stores (80 px).
    url = [url stringByReplacingOccurrencesOfString:@"=s[0-9]+" withString:@"=s80" options:NSRegularExpressionSearch range:NSMakeRange(0, url.length)];
    NSURL *address = [NSURL URLWithString:url];
    if (!address) { [waiting removeObjectForKey:channelID]; return; }
    [[[NSURLSession sharedSession] dataTaskWithURL:address completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *image = data ? [UIImage imageWithData:data] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray *callbacks = waiting[channelID];
            [waiting removeObjectForKey:channelID];
            if (!image) return;
            UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
            format.scale = 2;
            UIImage *square = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(40, 40) format:format] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                [image drawInRect:CGRectMake(0, 0, 40, 40)];
            }];
            gPictures[channelID] = square;
            for (void (^callback)(UIImage *) in callbacks) callback(square);
        });
    }] resume];
}

// A listed channel's missing picture, downloaded (a collaboration video shows them stacked).
static void fetchPicture(NSString *channelID) {
    NSInteger listed = channelIndex(channelID, nil);
    if (!channelID || listed == NSNotFound || gChannels[listed][@"avatar"]) return;
    loadPicture(channelID, ^(UIImage *picture) {
        NSInteger i = channelIndex(channelID, nil);
        if (i == NSNotFound || gChannels[i][@"avatar"]) return;
        NSMutableDictionary *entry = [gChannels[i] mutableCopy];
        entry[@"avatar"] = UIImagePNGRepresentation(picture);
        NSMutableArray *list = [gChannels mutableCopy];
        list[i] = entry;
        gChannels = [list copy];
        noteMissingAvatars();
        [[NSUserDefaults standardUserDefaults] setObject:gChannels forKey:kChannelsKey];
    });
}

// Adds a channel to the list, or takes it off if it's there. Returns the toast text.
static NSString *toggleChannel(NSString *channelID, NSString *name, UIView *avatarSource) {
    NSString *known = channelID.length ? gChannelInfo[channelID][@"name"] : nil;
    if ((!name.length || [name hasPrefix:@"@"]) && known.length) name = known;
    if (!channelID.length && !name.length) return @"Channel not found";
    NSString *shown = name ?: channelID;
    BOOL hiddenAfter = hiddenAfterToggle(channelID, name, nil);
    NSMutableArray *list = [gChannels mutableCopy] ?: [NSMutableArray array];
    NSInteger i = channelIndex(channelID, name);
    BOOL added = i == NSNotFound;
    if (added) {
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        if (channelID.length) entry[@"id"] = channelID;
        if (name.length) entry[@"name"] = name;
        NSData *avatar = avatarIn(avatarSource, name);
        if (avatar) entry[@"avatar"] = avatar;
        [list addObject:entry];
    } else {
        [list removeObjectAtIndex:(NSUInteger)i];
    }
    // A channel of the playing video: its choice from the player button goes, so the list decides.
    if (gVideoID && ([channelID isEqualToString:gVideoChannelID] || [videoOthers() containsObject:channelID]))
        [videoOverrides() removeObjectForKey:gVideoID];
    saveChannels(list);
    if (added) fetchPicture(channelID); // a collaboration channel's picture isn't on screen
    if (gChannelMode == 0)
        return [NSString stringWithFormat:added ? @"%@ added to the channel list. Choose a channel filter in settings." : @"%@ removed from the channel list", shown];
    return [NSString stringWithFormat:hiddenAfter ? @"Progress hidden for %@" : @"Progress shown for %@", shown];
}

// Whether a video's channels are offered one by one (chooseChannel): a collaboration video, with
// a channel filter. Include Collaborators only decides how a video is matched.
static BOOL offersChannels(NSArray<NSString *> *others) {
    return others.count && gChannelMode != 0;
}

static UIViewController *topViewController(void) {
    UIViewController *vc = keyWindow().rootViewController;
    while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) vc = vc.presentedViewController;
    return vc;
}

// A collaboration video's channels to pick from: each with its picture, its name and whether its
// videos' progress is hidden or shown; picking one adds it to the list or takes it off.
static const void *kMenuAddedKey = &kMenuAddedKey; // on a YTDefaultSheetController: our item is in
// The ⋯ menu item: for the video's channel, or the picker for a collaboration video's channels.
#define kHideItemTitle @"Hide progress for this channel"
#define kShowItemTitle @"Show progress for this channel"
#define kPickerItemTitle @"Progress by channel…"
static NSMutableDictionary<NSString *, NSString *> *gSheetStates; // picker rows: title -> state shown
// YouTube draws the watch page's More actions sheet (semibold text at x 61) unlike a feed video's
// ⋯ sheet (regular text at x 73): our items follow the sheet they were added to (picker sheets,
// the sheet they were opened from). Set when an item is added; kept per button once laid out.
static BOOL gWatchSheetStyle;
static const void *kWatchStyleKey = &kWatchStyleKey;
static NSMutableDictionary<NSString *, UIImage *> *gSheetIcons;   // picker rows: title -> picture (untinted)
static const NSInteger kStateLabelTag = 0x79746873;  // the state label on a picker row

// A channel's picture as a 24 pt circle, for a picker row; nil when there's none yet.
static UIImage *channelIcon(NSString *channelID) {
    UIImage *picture = channelID ? gPictures[channelID] : nil;
    NSInteger i = channelIndex(channelID, nil);
    NSData *data = i != NSNotFound ? gChannels[i][@"avatar"] : nil;
    if (!picture && [data isKindOfClass:[NSData class]]) picture = [UIImage imageWithData:data scale:2];
    if (!picture) return nil;
    UIImage *round = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(24, 24)] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, 24, 24)] addClip];
        [picture drawInRect:CGRectMake(0, 0, 24, 24)];
    }];
    return [round imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}
static void chooseChannel(NSString *channelID, NSString *name, NSArray<NSString *> *others, UIResponder *toastFrom) {
    NSString *message = @"Hide or show a channel's progress";
    UIViewController *top = topViewController();
    __weak UIResponder *weakFrom = toastFrom;
    // YouTube's own sheet (as in a video's ⋯ menu), else a system one.
    Class sheetClass = objc_getClass("YTDefaultSheetController");
    Class actionClass = objc_getClass("YTActionSheetAction");
    id sheet = nil;
    if ([sheetClass respondsToSelector:@selector(sheetControllerWithMessage:delegate:parentResponder:)])
        sheet = ((id (*)(id, SEL, id, id, id))objc_msgSend)(sheetClass, @selector(sheetControllerWithMessage:delegate:parentResponder:), message, nil, nil);
    else if ([sheetClass respondsToSelector:@selector(sheetControllerWithParentResponder:)])
        sheet = ((id (*)(id, SEL, id))objc_msgSend)(sheetClass, @selector(sheetControllerWithParentResponder:), nil);
    if (![sheet respondsToSelector:@selector(presentFromViewController:animated:completion:)]
        || ![actionClass respondsToSelector:@selector(actionWithTitle:iconImage:style:handler:)]) sheet = nil;
    UIAlertController *alert = sheet ? nil : [UIAlertController alertControllerWithTitle:nil message:message preferredStyle:UIAlertControllerStyleActionSheet];
    if (sheet) objc_setAssociatedObject(sheet, kMenuAddedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC); // not our own item again
    NSMutableOrderedSet<NSString *> *picks = [NSMutableOrderedSet orderedSetWithObject:channelID ?: @""];
    [picks addObjectsFromArray:others];
    for (NSString *pickID in picks) {
        NSString *pickName = pickID == channelID ? name : nil;
        NSString *known = pickID.length ? gChannelInfo[pickID][@"name"] : nil;
        if ((!pickName.length || [pickName hasPrefix:@"@"]) && known.length) pickName = known;
        if (!pickID.length && !pickName.length) continue;
        BOOL hidden = channelApplies(pickID, pickName, nil);
        NSString *title = pickName.length ? pickName : pickID;
        void (^pick)(void) = ^{ showToast(weakFrom ?: keyWindow().rootViewController, toggleChannel(pickID, pickName, nil)); };
        if (!gSheetStates) gSheetStates = [NSMutableDictionary dictionary];
        gSheetStates[title] = hidden ? @"Hidden" : @"Shown";
        UIImage *picture = channelIcon(pickID);
        if (!gSheetIcons) gSheetIcons = [NSMutableDictionary dictionary];
        if (picture) gSheetIcons[title] = picture;
        else [gSheetIcons removeObjectForKey:title];
        if (sheet) [sheet addAction:[actionClass actionWithTitle:title iconImage:picture ?: tweakIcon(24, hidden) style:0 handler:pick]];
        else [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { pick(); }]];
    }
    if (sheet) {
        ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(sheet, @selector(presentFromViewController:animated:completion:), top, YES, nil);
        return;
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    alert.popoverPresentationController.sourceView = top.view;
    alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMaxY(top.view.bounds), 1, 1);
    [top presentViewController:alert animated:YES completion:nil];
}

// Holding the player button adds or removes the video's channel.
static const void *kLongPressKey = &kLongPressKey;
static void addLongPress(UIView *overlay, NSDictionary <NSString *, YTQTMButton *> *buttons) {
    YTQTMButton *button = buttons[kOverlayTweakID];
    if (!button || objc_getAssociatedObject(button, kLongPressKey)) return;
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:overlay action:@selector(ythpHoldButton:)];
    [button addGestureRecognizer:hold];
    objc_setAssociatedObject(button, kLongPressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void holdButton(UIView *overlay, UILongPressGestureRecognizer *hold) {
    if (hold.state != UIGestureRecognizerStateBegan) return;
    UIViewController *player = nil;
    for (UIResponder *r = overlay; r && !player; r = r.nextResponder)
        if ([r isKindOfClass:[UIViewController class]]) player = playerFor((UIViewController *)r);
    if (player) updateVideoChannel(player);
    if (gVideoID) [videoOverrides() removeObjectForKey:gVideoID]; // the list decides again
    gWatchSheetStyle = YES;
    if (offersChannels(videoOthers())) chooseChannel(gVideoChannelID, gVideoChannelName, videoOthers(), overlay);
    else showToast(overlay, toggleChannel(gVideoChannelID, gVideoChannelName, keyWindow()));
}

// The main player (with YouTube's main overlay) in a view controller tree.
static UIViewController *mainPlayerIn(UIViewController *vc) {
    if (!vc) return nil;
    if ([vc isKindOfClass:objc_getClass("YTPlayerViewController")]
        && [valueAt(vc, @"activeVideoPlayerOverlay") isKindOfClass:objc_getClass("YTMainAppVideoPlayerOverlayViewController")]) return vc;
    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *found = mainPlayerIn(child);
        if (found) return found;
    }
    return mainPlayerIn(vc.presentedViewController);
}

// A video's ⋯ menu (YTDefaultSheetController): in a feed cell, the channel from the cell's
// label; the watch page's More actions button, the playing video's channel.
static void addChannelMenuItem(YTDefaultSheetController *sheet, UIView *source) {
    if (!source || objc_getAssociatedObject(sheet, kMenuAddedKey)) return;
    Class actionClass = objc_getClass("YTActionSheetAction");
    if (![actionClass respondsToSelector:@selector(actionWithTitle:iconImage:style:handler:)]) return;
    NSString *channelID = nil, *name = nil;
    NSArray<NSString *> *others = nil;
    BOOL watchPageButton = NO;
    if (!videoCellChannel(source, &name, &channelID, &others)) {
        // The watch page's More actions button sits in its action bar (with like, share and so on),
        // whatever the language; its English label is the fallback.
        BOOL moreActions = NO, watchPage = NO;
        UIView *v = source;
        for (int depth = 0; v && depth < 6; depth++, v = v.superview)
            if ([v.accessibilityIdentifier isEqualToString:@"id.video.non_scrollable_action_bar"]
                || (depth < 3 && [v.accessibilityLabel isEqualToString:@"More actions"])) moreActions = YES;
        for (UIResponder *r = source; r; r = r.nextResponder)
            if ([NSStringFromClass(r.class) hasPrefix:@"YTWatch"]) { watchPage = YES; break; }
        if (!moreActions || !watchPage) return;
        watchPageButton = YES;
        // Read the playing video's channel now: it may not have been read since the video changed.
        UIViewController *player = mainPlayerIn(keyWindow().rootViewController);
        if (player) updateVideoChannel(player);
        channelID = gVideoChannelID;
        name = gVideoChannelName;
        others = videoOthers();
    }
    if (!channelID.length && !name.length) return;
    // With All Channels the list changes nothing, so there's nothing to offer.
    if (gChannelMode == 0) return;
    objc_setAssociatedObject(sheet, kMenuAddedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // The picture comes from the cell (feeds; playlist rows have none) or, for the watch page's
    // button, the page's channel button: never any other part of the window.
    UIView *cell = source;
    while (cell && !isVideoLabel(cell.accessibilityLabel) && ![cell isKindOfClass:[UICollectionViewCell class]]) cell = cell.superview;
    UIView *avatarSource = watchPageButton ? keyWindow() : cell;
    completeChannel(channelID, name, avatarSource);
    BOOL hide = hiddenAfterToggle(channelID, name, nil);
    __weak UIView *weakSource = source, *weakAvatarSource = avatarSource;
    // A collaboration video: its channels to pick from, once the menu has closed.
    // The item works on the channel list (the player button is for the playing video only).
    BOOL choose = offersChannels(others);
    gWatchSheetStyle = watchPageButton;
    NSString *title = choose ? kPickerItemTitle : hide ? kHideItemTitle : kShowItemTitle;
    YTActionSheetAction *action = [actionClass actionWithTitle:title iconImage:tweakIcon(24, choose ? NO : hide) style:0 handler:^{
        UIResponder *from = weakSource;
        if (!from) from = keyWindow().rootViewController;
        if (choose) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ chooseChannel(channelID, name, others, from); });
            return;
        }
        showToast(from, toggleChannel(channelID, name, weakAvatarSource));
    }];
    [sheet addAction:action];
}

// The added item is a GOODialogActionMDCButton, which puts its text 8 pt further right than
// YouTube's own items (YTMenuItemMDCButton: 24 pt icon at 16, text at 64): line it up.
@interface GOODialogActionMDCButton : UIButton
@end
%hook GOODialogActionMDCButton
- (void)layoutSubviews {
    %orig;
    NSString *title = self.titleLabel.text;
    UILabel *state = [self viewWithTag:kStateLabelTag];
    BOOL ours = [@[kHideItemTitle, kShowItemTitle, kPickerItemTitle] containsObject:title] || gSheetStates[title];
    if (!ours) { [state removeFromSuperview]; return; }
    NSNumber *watchStyle = objc_getAssociatedObject(self, kWatchStyleKey);
    if (!watchStyle) {
        watchStyle = @(gWatchSheetStyle);
        objc_setAssociatedObject(self, kWatchStyleKey, watchStyle, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIImageView *icon = self.imageView;
    // The sheet tints its icons: a channel's picture goes back in as it is.
    UIImage *picture = gSheetIcons[title];
    if (picture && icon.image != picture) icon.image = picture;
    CGRect f = self.titleLabel.frame;
    if (watchStyle.boolValue) {
        // Like the watch page's own items (YouTube 20.42.3): 24 pt icon at x 16, semibold 16 pt
        // text at x 53 (the button starts 8 pt into the sheet).
        if (icon && !icon.hidden) {
            CGRect i = icon.frame;
            i.origin.x = 16;
            icon.frame = i;
        }
        self.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        self.titleLabel.textColor = UIColor.labelColor;
        f.origin.x = 53;
    } else if (icon && !icon.hidden) {
        // A feed sheet's items keep the button's own font; the text sits 24 pt after the icon.
        f.origin.x = CGRectGetMaxX(icon.frame) + 24;
    }
    // A picker row: the channel's state at the right end.
    NSString *stateText = gSheetStates[title];
    if (stateText) {
        if (!state) {
            state = [UILabel new];
            state.tag = kStateLabelTag;
            [self addSubview:state];
        }
        state.text = stateText;
        state.font = [UIFont systemFontOfSize:14];
        state.textColor = UIColor.secondaryLabelColor;
        [state sizeToFit];
        CGRect sf = state.frame;
        sf.origin.x = self.bounds.size.width - 24 - sf.size.width;
        sf.origin.y = CGRectGetMidY(f) - sf.size.height / 2;
        state.frame = sf;
        f.size.width = MIN(f.size.width, sf.origin.x - 12 - f.origin.x);
    } else [state removeFromSuperview];
    self.titleLabel.frame = f;
}
%end

%hook YTDefaultSheetController
- (void)presentFromView:(UIView *)view animated:(BOOL)animated completion:(id)completion {
    addChannelMenuItem(self, view ?: [self sourceView]);
    %orig;
}
- (void)presentFromViewController:(UIViewController *)vc animated:(BOOL)animated completion:(id)completion {
    addChannelMenuItem(self, [self sourceView]);
    %orig;
}
%end

%hook YTMainAppControlsOverlayView
- (UIImage *)buttonImage:(NSString *)tweakId {
    return [tweakId isEqualToString:kOverlayTweakID] ? buttonImage() : %orig;
}
- (void)layoutSubviews {
    %orig;
    if ([self respondsToSelector:@selector(overlayButtons)]) addLongPress(self, self.overlayButtons);
}
%new(v@:@)
- (void)didPressYTHideProgress:(id)sender {
    buttonPressed(self, self.overlayButtons);
}
%new(v@:@)
- (void)ythpHoldButton:(UILongPressGestureRecognizer *)hold {
    holdButton(self, hold);
}
%end

%hook YTInlinePlayerBarContainerView
- (UIImage *)buttonImage:(NSString *)tweakId {
    return [tweakId isEqualToString:kOverlayTweakID] ? buttonImage() : %orig;
}
%new(v@:@)
- (void)didPressYTHideProgress:(id)sender {
    buttonPressed(self, self.overlayButtons);
}
%new(v@:@)
- (void)ythpHoldButton:(UILongPressGestureRecognizer *)hold {
    holdButton(self, hold);
}
%end

// YTVideoOverlay may be in the app's Frameworks folder (sideloaded) or installed as a tweak.
static void registerPlayerButton(void) {
    NSString *inApp = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"Frameworks/YTVideoOverlay.dylib"];
    dlopen(inApp.fileSystemRepresentation, RTLD_LAZY);
    dlopen("/var/jb/Library/MobileSubstrate/DynamicLibraries/YTVideoOverlay.dylib", RTLD_LAZY);
    dlopen("/Library/MobileSubstrate/DynamicLibraries/YTVideoOverlay.dylib", RTLD_LAZY);
    Class manager = objc_getClass("YTSettingsSectionItemManager");
    YTHP_LOG(@"YTVideoOverlay %@", [manager respondsToSelector:@selector(registerTweak:metadata:)] ? @"found" : @"missing");
    if (![manager respondsToSelector:@selector(registerTweak:metadata:)]) return;
    [manager registerTweak:kOverlayTweakID metadata:@{
        @"accessibilityLabel": @"Progress Bar",
        @"selector": @"didPressYTHideProgress:",
        @"toggle": kButtonKey,              // shown or hidden from this tweak's settings
        @"updateImageOnVisible": @YES,
    }];
    gOverlayAvailable = YES;
}

// --- Settings: a section in YouTube's settings (under Tweaks with YouGroupSettings) ---

// YouGroupSettings adds +[YTSettingsGroupData tweaks] at runtime, possibly after this tweak
// loads, so the section is added to that list when the settings page asks for its categories.
static void registerWithGroupSettings(void) {
    Class cls = objc_getClass("YTSettingsGroupData");
    if (![cls respondsToSelector:@selector(tweaks)]) return;
    NSMutableArray <NSNumber *> *tweaks = [cls tweaks];
    if ([tweaks isKindOfClass:[NSMutableArray class]] && ![tweaks containsObject:@(TweakSection)]) [tweaks addObject:@(TweakSection)];
}

%hook YTSettingsGroupData
- (NSArray <NSNumber *> *)orderedCategories {
    registerWithGroupSettings();
    NSArray *orig = %orig;
    if (self.type != 1 || [objc_getClass("YTSettingsGroupData") respondsToSelector:@selector(tweaks)]) return orig;
    NSMutableArray *categories = [orig mutableCopy];
    if (![categories containsObject:@(TweakSection)]) [categories insertObject:@(TweakSection) atIndex:0];
    return categories;
}
%end

%hook YTAppSettingsPresentationData
+ (NSArray <NSNumber *> *)settingsCategoryOrder {
    registerWithGroupSettings();
    NSArray <NSNumber *> *order = %orig;
    if ([order containsObject:@(TweakSection)]) return order;
    NSUInteger i = [order indexOfObject:@(1)];
    if (i == NSNotFound) return order;
    NSMutableArray *m = [order mutableCopy];
    [m insertObject:@(TweakSection) atIndex:i + 1];
    return m;
}
%end

// --- The Channels page: the list, with each channel's picture; swipe a row to remove it. ---

static UIImage *channelAvatar(NSDictionary *channel, CGFloat side) {
    NSData *data = channel[@"avatar"];
    UIImage *picture = [data isKindOfClass:[NSData class]] ? [UIImage imageWithData:data scale:2] : nil;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGRect r = CGRectMake(0, 0, side, side);
        [[UIBezierPath bezierPathWithOvalInRect:r] addClip];
        if (picture) { [picture drawInRect:r]; return; }
        // No picture yet: the first letter on grey.
        [[UIColor colorWithWhite:0.35 alpha:1] setFill];
        UIRectFill(r);
        NSString *letter = [[(channel[@"name"] ?: @"?") substringToIndex:1] uppercaseString];
        NSDictionary *attrs = @{ NSFontAttributeName: [UIFont systemFontOfSize:side * 0.5 weight:UIFontWeightMedium], NSForegroundColorAttributeName: UIColor.whiteColor };
        CGSize t = [letter sizeWithAttributes:attrs];
        [letter drawAtPoint:CGPointMake((side - t.width) / 2, (side - t.height) / 2) withAttributes:attrs];
    }];
}

@interface YTHPChannelsViewController : UITableViewController
@property (nonatomic, copy) void (^onChange)(void);
@property (nonatomic, strong) UIColor *savedTint;
@end

@implementation YTHPChannelsViewController
- (instancetype)init {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) self.title = @"Channels";
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    // Like YouTube's own settings pages (UIKit's back button is clipped by YouTube's bar, which
    // has no side margin): a back arrow, then the page title in bold beside it.
    UIButton *back = [UIButton buttonWithType:UIButtonTypeSystem];
    [back setImage:[UIImage systemImageNamed:@"chevron.left" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightBold]] forState:UIControlStateNormal];
    back.tintColor = UIColor.labelColor;
    back.frame = CGRectMake(0, 0, 38, 44);
    back.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    back.contentEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 0);
    back.accessibilityLabel = @"Back";
    [back addTarget:self action:@selector(goBack) forControlEvents:UIControlEventTouchUpInside];
    UILabel *title = [UILabel new];
    title.text = self.title;
    title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    title.textColor = UIColor.labelColor;
    title.accessibilityTraits = UIAccessibilityTraitHeader;
    [title sizeToFit];
    self.navigationItem.leftBarButtonItems = @[[[UIBarButtonItem alloc] initWithCustomView:back], [[UIBarButtonItem alloc] initWithCustomView:title]];
    self.navigationItem.titleView = [UIView new]; // no centered title
    self.tableView.rowHeight = 56;
    self.tableView.backgroundColor = UIColor.systemBackgroundColor;
    [self updateEmptyState];
}
// YouTube's own pages have a white back button, not UIKit's blue.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    UINavigationBar *bar = self.navigationController.navigationBar;
    self.savedTint = bar.tintColor;
    bar.tintColor = UIColor.labelColor;
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.navigationController.navigationBar.tintColor = self.savedTint;
}
- (void)goBack {
    [self.navigationController popViewControllerAnimated:YES];
}
- (void)updateEmptyState {
    if (gChannels.count) { self.tableView.backgroundView = nil; return; }
    UILabel *label = [UILabel new];
    label.text = @"No channels\n\nHold the player button or use a video's menu to add a channel.";
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.secondaryLabelColor;
    label.font = [UIFont systemFontOfSize:15];
    UIView *box = [UIView new];
    [box addSubview:label];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [label.centerYAnchor constraintEqualToAnchor:box.centerYAnchor constant:-60],
        [label.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:32],
        [label.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-32],
    ]];
    self.tableView.backgroundView = box;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return gChannels.count;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"channel"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"channel"];
    NSDictionary *channel = gChannels[indexPath.row];
    UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
    content.text = channel[@"name"] ?: channel[@"id"];
    content.image = channelAvatar(channel, 36);
    content.imageProperties.maximumSize = CGSizeMake(36, 36);
    content.imageToTextPadding = 14;
    cell.contentConfiguration = content;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = UIColor.clearColor;
    return cell;
}
- (void)removeRow:(NSIndexPath *)indexPath {
    NSMutableArray *list = [gChannels mutableCopy];
    if ((NSUInteger)indexPath.row >= list.count) return;
    [list removeObjectAtIndex:indexPath.row];
    saveChannels(list);
    [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    [self updateEmptyState];
    if (self.onChange) self.onChange();
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    __weak typeof(self) weakSelf = self;
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Remove"
        handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
            [weakSelf removeRow:indexPath];
            done(YES);
        }];
    remove.image = [UIImage systemImageNamed:@"trash"];
    return [UISwipeActionsConfiguration configurationWithActions:@[remove]];
}
@end

// The settings list row for this tweak gets the tweak's icon. YouTube's section icons are its own
// built-in images (YTIIcon), so the icon is put into the row's empty icon spot (YTImageView).
@interface YTSettingsCell : UICollectionViewCell
@end
static const NSInteger kRowIconTag = 0x79746870; // 'ythp'
static const void *kRowIconHiddenKey = &kRowIconHiddenKey; // on YouTube's icon views the tweak hid

static void setYouTubeIconHidden(UIView *spot, BOOL hide) {
    for (UIView *sub in spot.subviews) {
        if (sub.tag == kRowIconTag) continue;
        if (hide && !sub.hidden) {
            sub.hidden = YES;
            objc_setAssociatedObject(sub, kRowIconHiddenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else if (!hide && [objc_getAssociatedObject(sub, kRowIconHiddenKey) boolValue]) {
            sub.hidden = NO;
            objc_setAssociatedObject(sub, kRowIconHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

%hook YTSettingsCell
- (void)layoutSubviews {
    %orig;
    UILabel *title = nil;
    UIView *iconSpot = nil;
    for (UIView *sub in self.contentView.subviews) {
        if (!title && [sub isKindOfClass:[UILabel class]] && ((UILabel *)sub).text.length) title = (UILabel *)sub;
        if (!iconSpot && [sub isKindOfClass:objc_getClass("YTImageView")]) iconSpot = sub;
    }
    if (!iconSpot) return;
    UIImageView *ours = [iconSpot viewWithTag:kRowIconTag];
    if (![title.text isEqualToString:@"YTHideProgress"]) {
        [ours removeFromSuperview];
        setYouTubeIconHidden(iconSpot, NO);
        return;
    }
    if (!ours) {
        ours = [[UIImageView alloc] initWithImage:tweakIcon(24, NO)];
        ours.tag = kRowIconTag;
        [iconSpot addSubview:ours];
    }
    ours.frame = iconSpot.bounds;
    ours.tintColor = title.textColor;
    [iconSpot bringSubviewToFront:ours];
    setYouTubeIconHidden(iconSpot, YES); // YouTube's default icon for a section without one
}
%end

// Reloads every settings page in a view controller and its children.
static void reloadSettingsPages(UIViewController *vc) {
    if ([vc isKindOfClass:objc_getClass("YTSettingsViewController")] && [vc respondsToSelector:@selector(reloadData)]) {
        YTHP_LOG(@"reload %@", vc);
        [vc performSelector:@selector(reloadData)];
    }
    for (UIViewController *child in vc.childViewControllers) reloadSettingsPages(child);
}

%hook YTSettingsSectionItemManager
%new(v@:@)
- (void)updateYTHideProgressSectionWithEntry:(id)entry {
    YTSettingsViewController *vc = [self valueForKey:@"_settingsViewControllerDelegate"];
    Class itemClass = %c(YTSettingsSectionItem);
    YTSettingsSectionItem *master = [itemClass
        switchItemWithTitle:@"Enabled"
           titleDescription:@"Turns every option below on or off. The player button hides or shows the progress for the playing video only."
    accessibilityIdentifier:nil
                   switchOn:gMaster
                switchBlock:^BOOL(id cell, BOOL on) {
                    setMaster(on);
                    return YES;
                }
              settingItemId:0];
    YTSettingsSectionItem *button = !gOverlayAvailable ? nil : [itemClass
        switchItemWithTitle:@"Player Button"
           titleDescription:@"Shows a button in the video player that hides or shows the progress for the playing video. Its place is set under Video Overlay."
    accessibilityIdentifier:nil
                   switchOn:[[NSUserDefaults standardUserDefaults] boolForKey:kButtonKey]
                switchBlock:^BOOL(id cell, BOOL on) {
                    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kButtonKey];
                    return YES;
                }
              settingItemId:0];
    YTSettingsSectionItem *portrait = [itemClass
        switchItemWithTitle:@"Hide in Portrait"
           titleDescription:@"Removes the thin line under the video while controls are not shown."
    accessibilityIdentifier:nil
                   switchOn:gEnabled
                switchBlock:^BOOL(id cell, BOOL on) {
                    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kEnabledKey];
                    gEnabled = on;
                    refreshAll();
                    return YES;
                }
              settingItemId:0];
    YTSettingsSectionItem *landscape = [itemClass
        switchItemWithTitle:@"Hide in Landscape"
           titleDescription:@"Removes the bar in landscape too while controls are not shown."
    accessibilityIdentifier:nil
                   switchOn:gLandscape
                switchBlock:^BOOL(id cell, BOOL on) {
                    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kLandscapeKey];
                    gLandscape = on;
                    refreshAll();
                    return YES;
                }
              settingItemId:0];
    YTSettingsSectionItem *always = [itemClass
        switchItemWithTitle:@"Hide With Controls"
           titleDescription:@"Also hides the bar and the time while the controls are shown."
    accessibilityIdentifier:nil
                   switchOn:gAlways
                switchBlock:^BOOL(id cell, BOOL on) {
                    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kAlwaysKey];
                    gAlways = on;
                    refreshAll();
                    return YES;
                }
              settingItemId:0];
    YTSettingsSectionItem *mini = [itemClass
        switchItemWithTitle:@"Hide in Miniplayer"
           titleDescription:@"Removes the line along the bottom of the floating player."
    accessibilityIdentifier:nil
                   switchOn:gMiniEnabled
                switchBlock:^BOOL(id cell, BOOL on) {
                    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kMiniEnabledKey];
                    gMiniEnabled = on;
                    refreshAll();
                    return YES;
                }
              settingItemId:0];
    id pipValue = [[NSUserDefaults standardUserDefaults] objectForKey:kPiPKey];
    YTSettingsSectionItem *pip = [itemClass
        switchItemWithTitle:@"Hide Picture in Picture Controls"
           titleDescription:@"Keeps the controls hidden when picture in picture starts. Tap the video to show them."
    accessibilityIdentifier:nil
                   switchOn:pipValue ? [pipValue boolValue] : YES
                switchBlock:^BOOL(id cell, BOOL on) {
                    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kPiPKey];
                    return YES;
                }
              settingItemId:0];
    id pipBarValue = [[NSUserDefaults standardUserDefaults] objectForKey:kPiPBarKey];
    YTSettingsSectionItem *pipBar = [itemClass
        switchItemWithTitle:@"Hide Picture in Picture Bar"
           titleDescription:@"Leaves the progress bar out of the picture in picture controls. Takes effect the next time picture in picture starts."
    accessibilityIdentifier:nil
                   switchOn:pipBarValue ? [pipBarValue boolValue] : YES
                switchBlock:^BOOL(id cell, BOOL on) {
                    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kPiPBarKey];
                    return YES;
                }
              settingItemId:0];
    __weak YTSettingsViewController *weakVC = vc; // the items' blocks are kept by vc
    __block NSArray *systemDependents = nil; // set below, once they exist
    YTSettingsSectionItem *system = [itemClass
        switchItemWithTitle:@"System Players"
           titleDescription:(sharedState() & 32)
               ? @"Paused: SpringBoard crashed twice soon after it loaded the tweak. Turn this off and on to try again."
               : @"Loads the tweak into SpringBoard and MediaRemoteUI for the picture in picture and Now Playing options below. Requires a respring."
    accessibilityIdentifier:nil
                   switchOn:[[NSUserDefaults standardUserDefaults] boolForKey:kSystemKey]
                switchBlock:^BOOL(id cell, BOOL on) {
                    YTHP_LOG(@"system switch %d", on);
                    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kSystemKey];
                    shareSystemPlayers(on);
                    // Grey out or enable the options below on the page that's showing (with
                    // YouGroupSettings it is its own page, built from these same items).
                    for (YTSettingsSectionItem *item in systemDependents)
                        if ([item respondsToSelector:@selector(setEnabled:)]) [item setValue:@(on) forKey:@"enabled"];
                    dispatch_async(dispatch_get_main_queue(), ^{ reloadSettingsPages(weakVC.navigationController.topViewController); });
                    // Back to what SpringBoard loaded (bit 4 of the shared state): nothing to respring for.
                    if (on != ((sharedState() & 4) != 0)) askToRespring(weakVC);
                    return YES;
                }
              settingItemId:0];
    // Channel filter: a picker for the mode, and the list (a row removes its channel).
    NSArray<NSString *> *modeNames = @[@"All Channels", @"Only Listed Channels", @"All Except Listed"];
    id parentResponder = [self respondsToSelector:@selector(parentResponder)] ? [(id)self valueForKey:@"parentResponder"] : nil;
    void (^push)(UIViewController *) = ^(UIViewController *page) {
        UINavigationController *nav = weakVC.navigationController;
        if ([weakVC respondsToSelector:@selector(pushViewController:)]) [weakVC performSelector:@selector(pushViewController:) withObject:page];
        else [nav pushViewController:page animated:YES];
    };
    BOOL canPick = [itemClass respondsToSelector:@selector(itemWithTitle:titleDescription:accessibilityIdentifier:detailTextBlock:selectBlock:)]
        && [itemClass respondsToSelector:@selector(checkmarkItemWithTitle:titleDescription:selectBlock:)] && objc_getClass("YTSettingsPickerViewController");
    YTSettingsSectionItem *channelMode = !canPick ? nil : [itemClass
        itemWithTitle:@"Channel Filter"
        titleDescription:@"Which channels' videos the tweak applies to, using the channel list."
        accessibilityIdentifier:nil
        detailTextBlock:^NSString *{ return modeNames[MIN(MAX(gChannelMode, 0), 2)]; }
        selectBlock:^BOOL(id cell, NSUInteger arg) {
            NSMutableArray *rows = [NSMutableArray array];
            for (NSUInteger i = 0; i < modeNames.count; i++) {
                [rows addObject:[itemClass checkmarkItemWithTitle:modeNames[i] titleDescription:nil selectBlock:^BOOL(id c, NSUInteger a) {
                    gChannelMode = i;
                    [[NSUserDefaults standardUserDefaults] setInteger:i forKey:kChannelModeKey];
                    refreshAll();
                    publishState();
                    reloadSettingsPages(weakVC.navigationController.topViewController);
                    for (UIViewController *page in weakVC.navigationController.viewControllers) reloadSettingsPages(page);
                    return YES;
                }]];
            }
            push([[objc_getClass("YTSettingsPickerViewController") alloc] initWithNavTitle:@"Channel Filter" pickerSectionTitle:nil rows:rows
                selectedItemIndex:(NSUInteger)gChannelMode parentResponder:parentResponder]);
            return YES;
        }];
    YTSettingsSectionItem *channelList = !canPick ? nil : [itemClass
        itemWithTitle:@"Channels"
        titleDescription:@"Hold the player button or use a video's menu to add a channel. Swipe a channel here to remove it."
        accessibilityIdentifier:nil
        detailTextBlock:^NSString *{ return [NSString stringWithFormat:@"%lu", (unsigned long)gChannels.count]; }
        selectBlock:^BOOL(id cell, NSUInteger arg) {
            YTHPChannelsViewController *page = [YTHPChannelsViewController new];
            page.onChange = ^{
                for (UIViewController *p in weakVC.navigationController.viewControllers) reloadSettingsPages(p);
            };
            push(page);
            return YES;
        }];
    YTSettingsSectionItem *collabs = !canPick ? nil : [itemClass
        switchItemWithTitle:@"Include Collaborators"
           titleDescription:@"A video with several channels counts as listed when any of them is listed."
    accessibilityIdentifier:nil
                   switchOn:gCollabs
                switchBlock:^BOOL(id cell, BOOL on) {
                    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kCollabsKey];
                    gCollabs = on;
                    refreshAll();
                    publishState();
                    return YES;
                }
              settingItemId:0];
    id lockValue = [[NSUserDefaults standardUserDefaults] objectForKey:kLockKey];
    YTSettingsSectionItem *watched = [itemClass
        switchItemWithTitle:@"Hide Watched Bar"
           titleDescription:@"Removes the red bar that shows how much of a video you watched from thumbnails."
    accessibilityIdentifier:nil
                   switchOn:gWatched
                switchBlock:^BOOL(id cell, BOOL on) {
                    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kWatchedKey];
                    gWatched = on;
                    refreshAll();
                    return YES;
                }
              settingItemId:0];
    YTSettingsSectionItem *length = [itemClass
        switchItemWithTitle:@"Hide Video Length"
           titleDescription:@"Removes the length shown in the corner of video thumbnails."
    accessibilityIdentifier:nil
                   switchOn:gLength
                switchBlock:^BOOL(id cell, BOOL on) {
                    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kLengthKey];
                    gLength = on;
                    refreshAll();
                    return YES;
                }
              settingItemId:0];
    YTSettingsSectionItem *lock = [itemClass
        switchItemWithTitle:@"Hide in Now Playing"
           titleDescription:@"Leaves the progress bar and the times out of the system media players, such as the Lock Screen, Control Center and the Dynamic Island."
    accessibilityIdentifier:nil
                   switchOn:lockValue ? [lockValue boolValue] : YES
                switchBlock:^BOOL(id cell, BOOL on) {
                    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kLockKey];
                    publishState();
                    return YES;
                }
              settingItemId:0];
    NSMutableArray *items = [NSMutableArray arrayWithObject:master];
    if (button) [items addObject:button];
    [items addObjectsFromArray:@[portrait, landscape, always, mini, watched, length]];
    if (channelMode) [items addObjectsFromArray:@[channelMode, channelList, collabs]];
    // The system options need the jailbreak part, which marks the shared state when loaded.
    if (sharedState() & 8) {
        // The options that need System Players are greyed out while it is off.
        BOOL systemOn = [[NSUserDefaults standardUserDefaults] boolForKey:kSystemKey];
        systemDependents = @[pip, pipBar, lock];
        for (YTSettingsSectionItem *item in systemDependents)
            if ([item respondsToSelector:@selector(setEnabled:)]) [item setValue:@(systemOn) forKey:@"enabled"];
        [items addObjectsFromArray:@[system, pip, pipBar, lock]];
    }
    if ([vc respondsToSelector:@selector(setSectionItems:forCategory:title:icon:titleDescription:headerHidden:)])
        [vc setSectionItems:items forCategory:TweakSection title:@"YTHideProgress" icon:nil titleDescription:nil headerHidden:NO];
    else
        [vc setSectionItems:items forCategory:TweakSection title:@"YTHideProgress" titleDescription:nil headerHidden:NO];
}
- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
    if (category == TweakSection) { [self updateYTHideProgressSectionWithEntry:entry]; return; }
    %orig;
}
%end



#ifdef YTHP_DEBUG
// Debug builds: put text in <tmp>/ythp-dump.txt and the view tree around the first view
// whose label contains it is logged (3 levels up, then everything below).
static void dumpTree(UIView *v, int depth, int maxDepth) {
    NSString *label = v.accessibilityLabel;
    if (label.length > 60) label = [[label substringToIndex:60] stringByAppendingString:@"…"];
    YTHP_LOG(@"%*s%@ %@ id=%@ a=%.2f h=%d %@", depth * 2, "", NSStringFromClass(v.class), NSStringFromCGRect(v.frame),
             v.accessibilityIdentifier, v.alpha, v.hidden, label ?: @"");
    if (depth >= maxDepth) return;
    for (UIView *sub in v.subviews) dumpTree(sub, depth + 1, maxDepth);
}
static UIView *findLabel(UIView *v, NSString *text) {
    if ([v.accessibilityLabel containsString:text]) return v;
    for (UIView *sub in v.subviews) { UIView *f = findLabel(sub, text); if (f) return f; }
    return nil;
}
static void startDumpWatcher(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ythp-dump.txt"];
    [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *t) {
        NSString *text = [[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!text.length) return;
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        UIView *found = nil;
        for (UIWindow *w in UIApplication.sharedApplication.windows) if ((found = findLabel(w, text))) break;
        YTHP_LOG(@"DUMP '%@' found=%@", text, found);
        UIView *top = found;
        for (int i = 0; i < 3 && top.superview; i++) top = top.superview;
        if (top) dumpTree(top, 0, 12);
    }];
}
#endif

%ctor {
    // Loaded twice (a YouTube IPA with the dylib inside, on a jailbreak that also has the
    // package): the first copy registers a marker class and does the work; later copies stay out.
#ifdef YTHP_DEBUG
    Dl_info selfInfo;
    dladdr((const void *)&publishState, &selfInfo);
    YTHP_LOG(@"load %s, already=%d", selfInfo.dli_fname, objc_getClass("YTHideProgressLoaded") != nil);
#endif
    if (objc_getClass("YTHideProgressLoaded")) return;
    Class marker = objc_allocateClassPair([NSObject class], "YTHideProgressLoaded", 0);
    if (marker) objc_registerClassPair(marker);
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults registerDefaults:@{ kButtonKey: @YES }];
    id master = [defaults objectForKey:kMasterKey];
    gMaster = master ? [master boolValue] : YES;
    gAlways = [defaults boolForKey:kAlwaysKey];
    id watched = [defaults objectForKey:kWatchedKey];
    gWatched = watched ? [watched boolValue] : YES;
    gLength = [defaults boolForKey:kLengthKey];
    gChannelMode = [defaults integerForKey:kChannelModeKey];
    gCollabs = [defaults objectForKey:kCollabsKey] ? [defaults boolForKey:kCollabsKey] : YES;
    id channels = [defaults objectForKey:kChannelsKey];
    gChannels = [channels isKindOfClass:[NSArray class]] ? channels : @[];
    noteMissingAvatars();
    registerPlayerButton(); // before YouTube builds its first player overlay
#ifdef YTHP_DEBUG
    dispatch_async(dispatch_get_main_queue(), ^{ startDumpWatcher(); });
#endif
    publishState();
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:kEnabledKey];
    gEnabled = v ? [v boolValue] : YES;
    gLandscape = [[NSUserDefaults standardUserDefaults] boolForKey:kLandscapeKey];
    id m = [[NSUserDefaults standardUserDefaults] objectForKey:kMiniEnabledKey];
    gMiniEnabled = m ? [m boolValue] : YES;
    %init;
}

