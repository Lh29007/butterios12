// iOS 12 entry point for Butterscotch: a Steam-style UIKit launcher.
//
// Each game is a folder in <Documents>/ containing data.win. Optional files in
// that folder customize the entry:
//   cover.png | cover.jpg   cover art (2:3 works best)
//   title.txt               display name (otherwise the folder name)
//   description.txt         description shown on the game page
// A data.win directly in Documents is also listed.

#import <UIKit/UIKit.h>

// The stb implementations must be defined before including the headers.
#define STB_IMAGE_IMPLEMENTATION
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include <stb_image.h>
#include <stb_image_write.h>

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <log.h>
#include <loop.h>
#include "bs_keys.h"

#define BS_BG   [UIColor colorWithRed:0.09 green:0.11 blue:0.15 alpha:1.0]
#define BS_CARD [UIColor colorWithRed:0.14 green:0.17 blue:0.23 alpha:1.0]
#define BS_ACCENT [UIColor colorWithRed:0.12 green:0.55 blue:0.85 alpha:1.0]

// ---------------------------------------------------------------------------
// Logging (required by the runner)
// ---------------------------------------------------------------------------

void platformLog(const logType type, const char *format, va_list va) {
    FILE *out = stderr;
    const char *textPrefix = "";

    switch (type) {
        case LOG_TYPE_NORMAL: out = stdout; break;
        case LOG_TYPE_WARNING: textPrefix = "Warning: "; break;
        case LOG_TYPE_ERROR: textPrefix = "Error: "; break;
        case LOG_TYPE_DEBUG: textPrefix = "Debug: "; break;
    }

    fputs(textPrefix, out);
    vfprintf(out, format, va);
}

// ---------------------------------------------------------------------------
// Games
// ---------------------------------------------------------------------------

@interface BSGame : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *folderName;
@property (nonatomic, copy) NSString *dataWinPath;
@property (nonatomic, copy) NSString *savesPath;
@property (nonatomic, copy) NSString *coverPath;   // may be nil
@property (nonatomic, copy) NSString *descriptionText;
@end

@implementation BSGame
@end

static NSString *documentsDirectory(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [paths firstObject];
}

static NSString *readText(NSString *path) {
    NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSArray<BSGame *> *scanGames(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *docs = documentsDirectory();
    NSMutableArray<BSGame *> *games = [NSMutableArray array];

    NSString *rootDataWin = [docs stringByAppendingPathComponent:@"data.win"];
    if ([fm fileExistsAtPath:rootDataWin]) {
        BSGame *g = [[BSGame alloc] init];
        g.name = @"Documents (data.win)";
        g.folderName = @"Documents";
        g.dataWinPath = rootDataWin;
        g.savesPath = [docs stringByAppendingPathComponent:@"saves"];
        g.descriptionText = @"";
        [games addObject:g];
    }

    for (NSString *entry in [fm contentsOfDirectoryAtPath:docs error:nil]) {
        if ([entry hasPrefix:@"."]) continue;
        NSString *dir = [docs stringByAppendingPathComponent:entry];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) continue;
        NSString *dataWin = [dir stringByAppendingPathComponent:@"data.win"];
        if (![fm fileExistsAtPath:dataWin]) continue;

        BSGame *g = [[BSGame alloc] init];
        g.folderName = entry;
        NSString *title = readText([dir stringByAppendingPathComponent:@"title.txt"]);
        g.name = title.length ? title : entry;
        g.descriptionText = readText([dir stringByAppendingPathComponent:@"description.txt"]) ?: @"";
        for (NSString *cover in @[@"cover.png", @"cover.jpg", @"cover.jpeg"]) {
            NSString *p = [dir stringByAppendingPathComponent:cover];
            if ([fm fileExistsAtPath:p]) { g.coverPath = p; break; }
        }
        g.dataWinPath = dataWin;
        g.savesPath = [dir stringByAppendingPathComponent:@"saves"];
        [games addObject:g];
    }

    [games sortUsingComparator:^NSComparisonResult(BSGame *a, BSGame *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    return games;
}

// Runs the runner on the main thread. Returns when the game exits.
static int runGame(BSGame *g) {
    setbuf(stdout, NULL);
    setbuf(stderr, NULL);
    fprintf(stderr, "iOS: launching %s\n", g.dataWinPath.fileSystemRepresentation);

    [[NSFileManager defaultManager] createDirectoryAtPath:g.savesPath
                              withIntermediateDirectories:YES attributes:nil error:nil];

    CommandLineArgs args = {0};
    args.exitAtFrame = -1;
#ifdef ENABLE_VM_TRACING
    args.traceBytecodeAfterFrame = 0;
#endif
    args.speedMultiplier = 1.0;
    args.fastForwardSpeed = 0.0;
    args.osType = OS_WINDOWS;
    args.profilerFramesBetween = 0;
    args.loadType = DATAWINLOADTYPE_LOAD_IN_MEMORY_AHEAD_OF_TIME;
#if defined(ENABLE_MODERN_GL)
    args.renderer = MODERN_GL;
#else
    args.renderer = SOFTWARE;
#endif
    // Fill the screen in landscape: use the screen size as the window size.
    CGRect screen = [UIScreen mainScreen].bounds;
    args.windowWidth = (int32_t)MAX(screen.size.width, screen.size.height);
    args.windowHeight = (int32_t)MIN(screen.size.width, screen.size.height);
    args.dataWinPath = strdup(g.dataWinPath.fileSystemRepresentation);
    args.saveFolder = strdup(g.savesPath.fileSystemRepresentation);

    return loop(args, "");
}

// Hides the launcher, starts the game, and closes the app when it exits.
static void launchGame(BSGame *g, UIWindow *window) {
    window.hidden = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        int ret = runGame(g);
        fprintf(stderr, "iOS: game returned %d, closing\n", ret);
        exit(ret);
    });
}

// ---------------------------------------------------------------------------
// Options: key mapping, touch controls, layout
// ---------------------------------------------------------------------------

static NSArray<NSString *> *positionKeys(void) {
    return @[@"stick", @"z", @"x", @"c", @"enter", @"shift", @"esc"];
}

static void resetKeyMapping(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    for (int i = 0; i < A_COUNT; i++) {
        [d removeObjectForKey:[NSString stringWithFormat:@"bs.map.%s", kActions[i].key]];
    }
}

static void resetLayout(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    for (NSString *p in positionKeys()) {
        [d removeObjectForKey:[@"bs.pos." stringByAppendingString:p]];
    }
}

static void styleCell(UITableViewCell *c) {
    c.backgroundColor = BS_CARD;
    c.textLabel.textColor = [UIColor whiteColor];
    c.detailTextLabel.textColor = [UIColor lightGrayColor];
}

@interface BSKeyChoiceVC : UITableViewController
@property (nonatomic, assign) int action;
@end

@implementation BSKeyChoiceVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [NSString stringWithUTF8String:kActions[self.action].label];
    self.tableView.backgroundColor = BS_BG;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)N_KEY_CHOICES;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    styleCell(cell);
    int vk = kKeyChoices[indexPath.row].vk;
    cell.textLabel.text = [NSString stringWithUTF8String:kKeyChoices[indexPath.row].name];
    cell.accessoryType = (BSMappedVK(self.action) == vk) ? UITableViewCellAccessoryCheckmark
                                                         : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    int vk = kKeyChoices[indexPath.row].vk;
    NSString *k = [NSString stringWithFormat:@"bs.map.%s", kActions[self.action].key];
    [[NSUserDefaults standardUserDefaults] setInteger:vk forKey:k];
    [self.navigationController popViewControllerAnimated:YES];
}

@end

@interface BSOptionsVC : UITableViewController
@end

// Sections: 0 = key mapping, 1 = touch controls, 2 = reset.
@implementation BSOptionsVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Options";
    self.tableView.backgroundColor = BS_BG;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"Touches";
        case 1: return @"Controles tactiles";
        default: return nil;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return A_COUNT;
        case 1: return 4;
        default: return 2;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                                   reuseIdentifier:nil];
    styleCell(cell);
    if (indexPath.section == 0) {
        cell.textLabel.text = [NSString stringWithUTF8String:kActions[indexPath.row].label];
        cell.detailTextLabel.text = [NSString stringWithUTF8String:BSKeyName(BSMappedVK(indexPath.row))];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 1 && indexPath.row < 3) {
        UISwitch *sw = [[UISwitch alloc] init];
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Afficher les controles";
            NSNumber *v = [d objectForKey:@"bs.touch.enabled"];
            sw.on = v ? [v boolValue] : YES;
            sw.tag = 1;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Deplacer les boutons au prochain lancement";
            cell.textLabel.numberOfLines = 0;
            sw.on = [d boolForKey:@"bs.edit.onstart"];
            sw.tag = 2;
        } else {
            cell.textLabel.text = @"Afficher les FPS";
            sw.on = [d boolForKey:@"bs.show.fps"];
            sw.tag = 3;
        }
        [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 1) {
        cell.textLabel.text = @"Reinitialiser la disposition";
        cell.textLabel.textColor = [UIColor redColor];
    } else {
        cell.textLabel.text = (indexPath.row == 0) ? @"Reinitialiser les touches"
                                                   : @"Reinitialiser la disposition";
        cell.textLabel.textColor = [UIColor redColor];
    }
    return cell;
}

- (void)switchChanged:(UISwitch *)sw {
    NSString *key = @"bs.edit.onstart";
    if (sw.tag == 1) key = @"bs.touch.enabled";
    else if (sw.tag == 3) key = @"bs.show.fps";
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:key];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        BSKeyChoiceVC *vc = [[BSKeyChoiceVC alloc] initWithStyle:UITableViewStyleGrouped];
        vc.action = (int)indexPath.row;
        [self.navigationController pushViewController:vc animated:YES];
    } else if (indexPath.section == 1 && indexPath.row == 3) {
        resetLayout();
        [self.tableView reloadData];
    } else if (indexPath.section == 2 && indexPath.row == 0) {
        resetKeyMapping();
        [self.tableView reloadData];
    } else if (indexPath.section == 2 && indexPath.row == 1) {
        resetLayout();
        [self.tableView reloadData];
    }
}

@end

// ---------------------------------------------------------------------------
// Game cards and grid
// ---------------------------------------------------------------------------

@interface BSGameCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *cover;
@property (nonatomic, strong) UILabel *initial;
@property (nonatomic, strong) UILabel *title;
@end

@implementation BSGameCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.contentView.backgroundColor = BS_CARD;
        self.contentView.layer.cornerRadius = 10;
        self.contentView.clipsToBounds = YES;

        _cover = [[UIImageView alloc] init];
        _cover.contentMode = UIViewContentModeScaleAspectFill;
        _cover.clipsToBounds = YES;
        _cover.backgroundColor = BS_ACCENT;
        [self.contentView addSubview:_cover];

        _initial = [[UILabel alloc] init];
        _initial.textAlignment = NSTextAlignmentCenter;
        _initial.font = [UIFont boldSystemFontOfSize:64];
        _initial.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.8];
        [_cover addSubview:_initial];

        _title = [[UILabel alloc] init];
        _title.textColor = [UIColor whiteColor];
        _title.font = [UIFont boldSystemFontOfSize:14];
        _title.numberOfLines = 2;
        [self.contentView addSubview:_title];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.contentView.bounds;
    CGFloat labelH = 44;
    self.cover.frame = CGRectMake(0, 0, b.size.width, b.size.height - labelH);
    self.initial.frame = self.cover.bounds;
    self.title.frame = CGRectMake(8, b.size.height - labelH, b.size.width - 16, labelH);
}

@end

@interface BSDetailVC : UIViewController <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, strong) BSGame *game;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIImageView *cover;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UILabel *folderLabel;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIButton *coverButton;
@property (nonatomic, strong) UIButton *descButton;
@end

@implementation BSDetailVC

- (UIButton *)secondaryButton:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.backgroundColor = BS_CARD;
    b.layer.cornerRadius = 10;
    b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.scroll addSubview:b];
    return b;
}

- (NSString *)gameDirectory {
    return [self.game.dataWinPath stringByDeletingLastPathComponent];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.game.name;
    self.view.backgroundColor = BS_BG;

    self.scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scroll.alwaysBounceVertical = YES;
    self.scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.scroll];

    self.cover = [[UIImageView alloc] init];
    self.cover.contentMode = UIViewContentModeScaleAspectFill;
    self.cover.clipsToBounds = YES;
    self.cover.backgroundColor = BS_CARD;
    if (self.game.coverPath) {
        self.cover.image = [UIImage imageWithContentsOfFile:self.game.coverPath];
    }
    [self.scroll addSubview:self.cover];

    self.playButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.playButton.backgroundColor = BS_ACCENT;
    self.playButton.layer.cornerRadius = 10;
    self.playButton.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    [self.playButton setTitle:@"JOUER" forState:UIControlStateNormal];
    [self.playButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.playButton addTarget:self action:@selector(play) forControlEvents:UIControlEventTouchUpInside];
    [self.scroll addSubview:self.playButton];

    self.coverButton = [self secondaryButton:@"Changer la jaquette" action:@selector(changeCover)];
    self.descButton = [self secondaryButton:@"Modifier la description" action:@selector(editDescription)];
    // The root data.win entry lives directly in Documents: no per-game files there.
    BOOL isRoot = [self.game.folderName isEqualToString:@"Documents"];
    self.coverButton.hidden = isRoot;
    self.descButton.hidden = isRoot;

    self.descLabel = [[UILabel alloc] init];
    self.descLabel.numberOfLines = 0;
    self.descLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    self.descLabel.font = [UIFont systemFontOfSize:16];
    self.descLabel.text = self.game.descriptionText.length
        ? self.game.descriptionText
        : @"Pas de description. Touche Modifier la description pour en ajouter une.";
    [self.scroll addSubview:self.descLabel];

    self.folderLabel = [[UILabel alloc] init];
    self.folderLabel.textColor = [UIColor grayColor];
    self.folderLabel.font = [UIFont systemFontOfSize:12];
    self.folderLabel.text = [NSString stringWithFormat:@"Dossier : %@", self.game.folderName];
    [self.scroll addSubview:self.folderLabel];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    CGFloat pad = 24;
    CGFloat coverH = 300;
    CGFloat rowY = coverH + 20;
    self.scroll.frame = self.view.bounds;
    self.cover.frame = CGRectMake(0, 0, w, coverH);
    self.playButton.frame = CGRectMake(pad, rowY, 200, 52);
    self.coverButton.frame = CGRectMake(pad + 216, rowY, 190, 52);
    self.descButton.frame = CGRectMake(pad + 422, rowY, 200, 52);
    CGFloat y = rowY + 52 + 24;
    CGSize d = [self.descLabel sizeThatFits:CGSizeMake(w - 2 * pad, CGFLOAT_MAX)];
    self.descLabel.frame = CGRectMake(pad, y, w - 2 * pad, d.height);
    y += d.height + 24;
    self.folderLabel.frame = CGRectMake(pad, y, w - 2 * pad, 16);
    y += 16 + pad;
    self.scroll.contentSize = CGSizeMake(w, y);
}

- (void)play {
    launchGame(self.game, self.view.window);
}

- (void)changeCover {
    if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]) return;
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker
didFinishPickingMediaWithInfo:(NSDictionary *)info {
    UIImage *img = info[UIImagePickerControllerOriginalImage];
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!img) return;
    NSString *path = [[self gameDirectory] stringByAppendingPathComponent:@"cover.png"];
    if ([UIImagePNGRepresentation(img) writeToFile:path atomically:YES]) {
        self.game.coverPath = path;
        self.cover.image = img;
    }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)editDescription {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Description"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = self.game.descriptionText;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Annuler"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Enregistrer"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *act) {
        NSString *text = alert.textFields.firstObject.text ?: @"";
        NSString *path = [[self gameDirectory] stringByAppendingPathComponent:@"description.txt"];
        [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        self.game.descriptionText = text;
        self.descLabel.text = text.length ? text : @"Pas de description.";
        [self.view setNeedsLayout];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

@interface BSLauncherVC : UICollectionViewController
@property (nonatomic, strong) NSArray<BSGame *> *games;
@end

@implementation BSLauncherVC

- (instancetype)init {
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.minimumInteritemSpacing = 16;
    layout.minimumLineSpacing = 16;
    layout.sectionInset = UIEdgeInsetsMake(16, 16, 16, 16);
    return [super initWithCollectionViewLayout:layout];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Butterscotch";
    self.collectionView.backgroundColor = BS_BG;
    self.collectionView.alwaysBounceVertical = YES;
    [self.collectionView registerClass:[BSGameCell class] forCellWithReuseIdentifier:@"game"];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Options" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(openOptions)];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Actualiser" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(reload)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    self.games = scanGames();
    if (self.games.count == 0) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(20, 80, self.view.bounds.size.width - 40, 200)];
        label.numberOfLines = 0;
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = [UIColor grayColor];
        label.text = @"Aucun jeu trouve.\n\nCree un dossier dans Documents (par ex. DELTARUNE/)\net mets-y le fichier data.win.";
        self.collectionView.backgroundView = label;
    } else {
        self.collectionView.backgroundView = nil;
    }
    [self.collectionView reloadData];
}

- (void)openOptions {
    BSOptionsVC *vc = [[BSOptionsVC alloc] initWithStyle:UITableViewStyleGrouped];
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - Data source

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView { return 1; }

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)self.games.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    BSGameCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"game" forIndexPath:indexPath];
    BSGame *g = self.games[indexPath.item];
    cell.title.text = g.name;
    cell.initial.text = [[g.name substringToIndex:MIN((NSUInteger)1, g.name.length)] uppercaseString];
    cell.cover.image = g.coverPath ? [UIImage imageWithContentsOfFile:g.coverPath] : nil;
    cell.initial.hidden = (cell.cover.image != nil);
    return cell;
}

#pragma mark - Layout

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout
  sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    CGFloat width = collectionView.bounds.size.width;
    NSInteger cols = (width > 700) ? 4 : 2;
    CGFloat itemW = (width - 16.0 * (cols + 1)) / cols;
    CGFloat coverH = itemW * 1.45;
    return CGSizeMake(itemW, coverH + 44);
}

#pragma mark - Selection

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    BSDetailVC *vc = [[BSDetailVC alloc] init];
    vc.game = self.games[indexPath.item];
    [self.navigationController pushViewController:vc animated:YES];
}

@end

// ---------------------------------------------------------------------------
// App lifecycle
// ---------------------------------------------------------------------------

@interface BSAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation BSAppDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application; (void)launchOptions;

    UINavigationBar *bar = [UINavigationBar appearance];
    bar.barStyle = UIBarStyleBlack;
    bar.barTintColor = BS_BG;
    bar.tintColor = [UIColor whiteColor];
    bar.titleTextAttributes = @{NSForegroundColorAttributeName: [UIColor whiteColor]};

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = BS_BG;
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:[[BSLauncherVC alloc] init]];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([BSAppDelegate class]));
    }
}
