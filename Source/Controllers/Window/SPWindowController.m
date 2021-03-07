//
//  SPWindowController.m
//  sequel-pro
//
//  Created by Rowan Beentje on May 16, 2010.
//  Copyright (c) 2010 Rowan Beentje. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person
//  obtaining a copy of this software and associated documentation
//  files (the "Software"), to deal in the Software without
//  restriction, including without limitation the rights to use,
//  copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following
//  conditions:
//
//  The above copyright notice and this permission notice shall be
//  included in all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
//  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
//  OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
//  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
//  HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
//  WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
//  OTHER DEALINGS IN THE SOFTWARE.
//
//  More info at <https://github.com/sequelpro/sequelpro>

#import "SPWindowController.h"
#import "SPDatabaseDocument.h"
#import "SPAppController.h"
#import "PSMTabDragAssistant.h"
#import "SPConnectionController.h"
#import "SPFavoritesOutlineView.h"
#import "SPWindow.h"

#import "PSMTabBarControl.h"
#import "PSMTabStyle.h"

#import "sequel-ace-Swift.h"

@interface SPWindowController ()

- (void)_setUpTabBar;
- (void)_updateProgressIndicatorForItem:(NSTabViewItem *)theItem;
- (void)_switchOutSelectedTableDocument:(SPDatabaseDocument *)newDoc;
- (void)_selectedTableDocumentDeallocd:(NSNotification *)notification;

@property (readwrite, strong) SPDatabaseDocument *selectedTableDocument;

#pragma mark - SPWindowControllerDelegate

- (void)tabDragStarted:(id)sender;
- (void)tabDragStopped:(id)sender;

@end

@implementation SPWindowController

#pragma mark -
#pragma mark Initialisation

- (void)awakeFromNib {
    [super awakeFromNib];

    [self setupAppearance];
    [self setupConstraints];

    [self _switchOutSelectedTableDocument:nil];

    NSWindow *window = [self window];

    [window setCollectionBehavior:[window collectionBehavior] | NSWindowCollectionBehaviorFullScreenPrimary];

    // Disable automatic cascading - this occurs before the size is set, so let the app
    // controller apply cascading after frame autosaving.
    [self setShouldCascadeWindows:NO];

    // Initialise the managed database connections array
    managedDatabaseConnections = [[NSMutableArray alloc] init];

    [self _setUpTabBar];

    // Retrieve references to the 'Close Window' and 'Close Tab' menus.  These are updated as window focus changes.
    NSMenu *mainMenu = [NSApp mainMenu];
    _closeWindowMenuItem = [[[mainMenu itemWithTag:SPMainMenuFile] submenu] itemWithTag:SPMainMenuFileClose];
    _closeTabMenuItem = [[[mainMenu itemWithTag:SPMainMenuFile] submenu] itemWithTag:SPMainMenuFileCloseTab];

    // Register for drag start and stop notifications - used to show/hide tab bars
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(tabDragStarted:) name:PSMTabDragDidBeginNotification object:nil];
    [nc addObserver:self selector:@selector(tabDragStopped:) name:PSMTabDragDidEndNotification object:nil];

    // Because we are a document-based app we automatically adopt window restoration on 10.7+.
    // However that causes a race condition with our own window setup code.
    // Remove this when we actually support restoration.
    if ([window respondsToSelector:@selector(setRestorable:)]) {
        [window setRestorable:NO];
    }
}

#pragma mark -
#pragma mark Database connection management

/**
 * Add a new database connection to the window, in a tab view.
 */
- (IBAction)addNewConnection:(id)sender
{
	[self addNewConnection];
}

- (SPDatabaseDocument *)addNewConnection
{
	// Create a new database connection view
	SPDatabaseDocument *databaseDocument = [[SPDatabaseDocument alloc] initWithWindowController:self];

	// Set up a new tab with the connection view as the identifier, add the view, and add it to the tab view
    NSTabViewItem *newItem = [[NSTabViewItem alloc] initWithIdentifier:databaseDocument];

    if(newItem != nil){
        [newItem setView:[databaseDocument databaseView]];
        [self.tabView addTabViewItem:newItem];
        [self.tabView selectTabViewItem:newItem];
        [databaseDocument setParentTabViewItem:newItem];

        // Tell the new database connection view to set up the window and update titles
        [databaseDocument didBecomeActiveTabInWindow];
        [databaseDocument updateWindowTitle:self];

        // Bind the tab bar's progress display to the document
        [self _updateProgressIndicatorForItem:newItem];
    }
    else{
        [NSAlert createWarningAlertWithTitle:NSLocalizedString(@"New Connection Error", @"New Connection Error") message:NSLocalizedString(@"Failed to create new database connection window. Please restart Sequel Ace and try again.", @"New Connection Error informative message") callback:nil];
        SPLog(@"Failed to create new NSTabViewItem. databaseDocument = %@", databaseDocument);
    }

    return databaseDocument;
}

/**
 * Update the currently selected connection view
 */
- (void)updateSelectedTableDocument
{
	[self _switchOutSelectedTableDocument:[[self.tabView selectedTabViewItem] databaseDocument]];
	
	[self.selectedTableDocument didBecomeActiveTabInWindow];
}

/**
 * Ask all the connection views to update their titles.
 * As tab titles depend on the currently selected tab, changes
 * within each tab may require other tabs to update their titles.
 * If the sender is a tab, that tab is skipped when updating titles.
 */
- (void)updateAllTabTitles:(id)sender
{
	for (NSTabViewItem *eachItem in [self.tabView tabViewItems])
	{
		SPDatabaseDocument *eachDocument = [eachItem databaseDocument];
		
		if (eachDocument != sender) {
			[eachDocument updateWindowTitle:self];
		}
	}
}

/**
 * Close the current tab, or if it's the last in the window, the window.
 */
- (IBAction)closeTab:(id)sender
{
	// If there are multiple tabs, close the front tab.
	if ([self.tabView numberOfTabViewItems] > 1) {
		// Return if the selected tab shouldn't be closed
        if (![self.selectedTableDocument parentTabShouldClose]) {
            return;
        }
        if([[self.tabView tabViewItems] containsObject:[self.tabView selectedTabViewItem]] == YES){
            [self.tabView removeTabViewItem:[self.tabView selectedTabViewItem]];
        }
	} 
	else {
		//trying to close the window will itself call parentTabShouldClose for all tabs in windowShouldClose:
		[[self window] performClose:self];
        [self.delegate windowControllerDidClose:self];
	}
}

/**
 * Select next tab; if last select first one.
 */
- (IBAction) selectNextDocumentTab:(id)sender
{
	if ([self.tabView indexOfTabViewItem:[self.tabView selectedTabViewItem]] == [self.tabView numberOfTabViewItems] - 1) {
		[self.tabView selectFirstTabViewItem:nil];
	}
	else {
		[self.tabView selectNextTabViewItem:nil];
	}
}

/**
 * Select previous tab; if first select last one.
 */
- (IBAction) selectPreviousDocumentTab:(id)sender
{
	if ([self.tabView indexOfTabViewItem:[self.tabView selectedTabViewItem]] == 0) {
		[self.tabView selectLastTabViewItem:nil];
	}
	else {
		[self.tabView selectPreviousTabViewItem:nil];
	}
}

/**
 * Move the currently selected tab to a new window.
 */
- (IBAction)moveSelectedTabInNewWindow:(id)sender {
	static NSPoint cascadeLocation = {.x = 0, .y = 0};

	NSTabViewItem *selectedTabViewItem = [self.tabView selectedTabViewItem];
    SPDatabaseDocument *selectedDocument = [selectedTabViewItem databaseDocument];
	PSMTabBarCell *selectedCell = [[self.tabBarControl cells] objectAtIndex:[self.tabView indexOfTabViewItem:selectedTabViewItem]];

    SPWindowController *newWindowController = [[SPWindowController alloc] initWithWindowNibName:@"MainWindow"];
    [self.delegate windowControllerDidCreateNewWindowController:newWindowController];
	NSWindow *newWindow = [newWindowController window];

	CGFloat toolbarHeight = 0;
	
	if ([[[self window] toolbar] isVisible]) {
		NSRect innerFrame = [NSWindow contentRectForFrameRect:[[self window] frame] styleMask:[[self window] styleMask]];
		toolbarHeight = innerFrame.size.height - [[[self window] contentView] frame].size.height;
	}
	
	// Set the new window position and size
	NSRect targetWindowFrame = [[self window] frame];
	targetWindowFrame.size.height -= toolbarHeight;
	[newWindow setFrame:targetWindowFrame display:NO];

	// Cascade according to the statically stored cascade location.
	cascadeLocation = [newWindow cascadeTopLeftFromPoint:cascadeLocation];

	// Set the window controller as the window's delegate
	[newWindow setDelegate:newWindowController];

	// Set window title
	[newWindow setTitle:[[selectedDocument parentWindowControllerWindow] title]];

	// New window's self.tabBarControl control
	PSMTabBarControl *control = newWindowController.tabBarControl;

	// Add the selected tab to the new window
	[[control cells] insertObject:selectedCell atIndex:0];

	// Remove 'isProcessing' observer from old windowController
	[selectedDocument removeObserver:self forKeyPath:@"isProcessing"];

	// Update new 'isProcessing' observer and bind the new tab bar's progress display to the document
	[self _updateProgressIndicatorForItem:selectedTabViewItem];

	//remove the tracking rects and bindings registered on the old tab
	[self.tabBarControl removeTrackingRect:[selectedCell closeButtonTrackingTag]];
	[self.tabBarControl removeTrackingRect:[selectedCell cellTrackingTag]];
	[self.tabBarControl removeTabForCell:selectedCell];

	//rebind the selected cell to the new control
	[control bindPropertiesForCell:selectedCell andTabViewItem:selectedTabViewItem];
	
	[selectedCell setCustomControlView:control];

    if([[self.tabBarControl.tabView tabViewItems] containsObject:[selectedCell representedObject]] == YES){
        [[self.tabBarControl tabView] removeTabViewItem:[selectedCell representedObject]];
    }
	[[control tabView] addTabViewItem:selectedTabViewItem];

	// Make sure the new tab is set in the correct position by forcing an update
	[self.tabBarControl update];

	// Update self.tabBarControl of the new window
	[newWindowController tabView:[self.tabBarControl tabView] didDropTabViewItem:[selectedCell representedObject] inTabBar:control];

	[newWindow makeKeyAndOrderFront:nil];	
}

/**
 * Menu item validation.
 */
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
	// Select Next/Previous/Move Tab
	if ([menuItem action] == @selector(selectPreviousDocumentTab:) ||
		[menuItem action] == @selector(selectNextDocumentTab:) ||
		[menuItem action] == @selector(moveSelectedTabInNewWindow:))
	{
		return ([self.tabView numberOfTabViewItems] != 1);
	}
	
	// See if the front document blocks validation of this item
	if (![self.selectedTableDocument validateMenuItem:menuItem]) return NO;

	return YES;
}

/**
 * Retrieve the documents associated with this window.
 */
- (NSArray <SPDatabaseDocument *> *)documents {
	NSMutableArray <SPDatabaseDocument *> *documentsArray = [NSMutableArray array];
	for (NSTabViewItem *eachItem in [self.tabView tabViewItems]) {
		[documentsArray safeAddObject:[eachItem databaseDocument]];
	}
	return documentsArray;
}

/**
 * Select tab at index.
 */
- (void)selectTabAtIndex:(NSInteger)index
{
	if ([[self.tabBarControl cells] count] > 0 && [[self.tabBarControl cells] count] > (NSUInteger)index) {
		[self.tabView selectTabViewItemAtIndex:index];
	} 
	else if ([[self.tabBarControl cells] count]) {
		[self.tabView selectTabViewItemAtIndex:0];
	}
}

/**
 * Opens the current connection in a new tab, but only if it's already connected.
 */
- (void)openDatabaseInNewTab
{
	if ([self.selectedTableDocument database]) {
		[self.selectedTableDocument openDatabaseInNewTab:self];
	}
}

#pragma mark -
#pragma mark Tab Bar
- (void)updateTabBar
{
	BOOL collapse = NO;
 
	if (self.selectedTableDocument.getConnection) {
		if (self.selectedTableDocument.connectionController.colorIndex != -1) {
			collapse = YES;
		}
	}
	
	[self.tabBarControl update];
}

#pragma mark -
#pragma mark First responder forwarding to active tab

/**
 * Delegate unrecognised methods to the selected table document, thanks to the magic
 * of NSInvocation (see forwardInvocation: docs for background). Must be paired
 * with methodSignationForSelector:.
 */
- (void)forwardInvocation:(NSInvocation *)theInvocation
{
	SEL theSelector = [theInvocation selector];
	
	if (![self.selectedTableDocument respondsToSelector:theSelector]) {
		[self doesNotRecognizeSelector:theSelector];
	}
	
	[theInvocation invokeWithTarget:self.selectedTableDocument];
}

/**
 * Return the correct method signatures for the selected table document if
 * NSObject doesn't implement the requested methods.
 */
- (NSMethodSignature *)methodSignatureForSelector:(SEL)theSelector
{
	NSMethodSignature *defaultSignature = [super methodSignatureForSelector:theSelector];
	
	return defaultSignature ? defaultSignature : [self.selectedTableDocument methodSignatureForSelector:theSelector];
}

/**
 * Override the default repondsToSelector:, returning true if either NSObject
 * or the selected table document supports the selector.
 */
- (BOOL)respondsToSelector:(SEL)theSelector
{
	return ([super respondsToSelector:theSelector] || [self.selectedTableDocument respondsToSelector:theSelector]);
}

/**
 * When receiving an update for a bound value - an observed value on the
 * document - ask the tab bar control to redraw as appropriate.
 */
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    [self.tabBarControl update];
}

#pragma mark -
#pragma mark Private API

/**
 * Set up the window's tab bar.
 */
- (void)_setUpTabBar
{
	[self.tabBarControl setStyleNamed:@"SequelPro"];
	[self.tabBarControl setCanCloseOnlyTab:NO];
	[self.tabBarControl setShowAddTabButton:YES];
	[self.tabBarControl setSizeCellsToFit:NO];
	[self.tabBarControl setCellMinWidth:100];
	[self.tabBarControl setCellMaxWidth:25000];
	[self.tabBarControl setCellOptimumWidth:25000];
	[self.tabBarControl setSelectsTabsOnMouseDown:YES];
	[self.tabBarControl setCreatesTabOnDoubleClick:YES];
	[self.tabBarControl setTearOffStyle:PSMTabBarTearOffAlphaWindow];
	[self.tabBarControl setUsesSafariStyleDragging:YES];
	
	// Hook up add tab button
	[self.tabBarControl setCreateNewTabTarget:self];
	[self.tabBarControl setCreateNewTabAction:@selector(addNewConnection:)];
	
	// Set the double click target and action
	[self.tabBarControl setDoubleClickTarget:self];
	[self.tabBarControl setDoubleClickAction:@selector(openDatabaseInNewTab)];
}

/**
 * Binds a tab bar item's progress indicator to the represented tableDocument.
 */
- (void)_updateProgressIndicatorForItem:(NSTabViewItem *)theItem
{
	PSMTabBarCell *theCell = [[self.tabBarControl cells] objectAtIndex:[self.tabView indexOfTabViewItem:theItem]];
	
	[[theCell indicator] setControlSize:NSControlSizeSmall];
	
	SPDatabaseDocument *theDocument = [theItem databaseDocument];
	
	[[theCell indicator] setHidden:NO];
	
	NSMutableDictionary *bindingOptions = [NSMutableDictionary dictionary];
	
	[bindingOptions setObject:NSNegateBooleanTransformerName forKey:@"NSValueTransformerName"];
	
	[[theCell indicator] bind:@"animate" toObject:theDocument withKeyPath:@"isProcessing" options:nil];
	[[theCell indicator] bind:@"hidden" toObject:theDocument withKeyPath:@"isProcessing" options:bindingOptions];
	
	[theDocument addObserver:self forKeyPath:@"isProcessing" options:0 context:nil];
}

- (void)_switchOutSelectedTableDocument:(SPDatabaseDocument *)newDoc
{
	NSAssert([NSThread isMainThread], @"Switching the selectedTableDocument via a background thread is not supported!");
	
	// shortcut if there is nothing to do
    if (self.selectedTableDocument == newDoc) {
        return;
    }
	
	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	if (self.selectedTableDocument) {
		[nc removeObserver:self name:SPDocumentWillCloseNotification object:self.selectedTableDocument];
		self.selectedTableDocument = nil;
	}
	if (newDoc) {
		[nc addObserver:self selector:@selector(_selectedTableDocumentDeallocd:) name:SPDocumentWillCloseNotification object:newDoc];
		self.selectedTableDocument = newDoc;
	}
	
	[self updateTabBar];
}

- (void)_selectedTableDocumentDeallocd:(NSNotification *)notification
{
	[self _switchOutSelectedTableDocument:nil];
}

#pragma mark -
#pragma mark Tab view delegate methods

/**
 * Called when a tab item is about to be selected.
 */
- (void)tabView:(NSTabView *)tabView willSelectTabViewItem:(NSTabViewItem *)tabViewItem
{
	[self.selectedTableDocument willResignActiveTabInWindow];
}

/**
 * Called when a tab item was selected.
 */
- (void)tabView:(NSTabView *)tabView didSelectTabViewItem:(NSTabViewItem *)tabViewItem
{
	if ([[PSMTabDragAssistant sharedDragAssistant] isDragging]) return;

	[self _switchOutSelectedTableDocument:[tabViewItem databaseDocument]];
	[self.selectedTableDocument didBecomeActiveTabInWindow];

    if ([[self window] isKeyWindow]) {
        [self.selectedTableDocument tabDidBecomeKey];
    }

	[self updateAllTabTitles:self];
}

/**
 * Called to determine whether a tab view item can be closed
 *
 * Note: This is ONLY called when using the "X" button on the tab itself.
 */
- (BOOL)tabView:(NSTabView *)aTabView shouldCloseTabViewItem:(NSTabViewItem *)tabViewItem
{
	SPDatabaseDocument *theDocument = [tabViewItem databaseDocument];

    if (![theDocument parentTabShouldClose]) {
        return NO;
    }
	return YES;
}

/**
 * Called after a tab view item is closed.
 */
- (void)tabView:(NSTabView *)aTabView didCloseTabViewItem:(NSTabViewItem *)tabViewItem
{
	SPDatabaseDocument *theDocument = [tabViewItem databaseDocument];

	[theDocument removeObserver:self forKeyPath:@"isProcessing"];
	[theDocument parentTabDidClose];
}

/**
 * Called to allow dragging of tab view items
 */
- (BOOL)tabView:(NSTabView *)aTabView shouldDragTabViewItem:(NSTabViewItem *)tabViewItem fromTabBar:(PSMTabBarControl *)tabBarControl
{
	return YES;
}

/**
 * Called when a tab finishes a drop.  This is called with the new tabView.
 */
- (void)tabView:(NSTabView*)aTabView didDropTabViewItem:(NSTabViewItem *)tabViewItem inTabBar:(PSMTabBarControl *)tabBarControl
{
	SPDatabaseDocument *draggedDocument = [tabViewItem databaseDocument];

	// Grab a reference to the old window
	NSWindow *draggedFromWindow = [draggedDocument parentWindowControllerWindow];

	// If the window changed, perform additional processing.
	if (draggedFromWindow != [tabBarControl window]) {

		// Update the old window, ensuring the toolbar is cleared to prevent issues with toolbars in multiple windows
		[draggedFromWindow setToolbar:nil];
		[[draggedFromWindow windowController] updateSelectedTableDocument];

		// Update the item's document's window and controller
		[draggedDocument willResignActiveTabInWindow];
        [draggedDocument updateParentWindowController:[[tabBarControl window] windowController]];
		[draggedDocument didBecomeActiveTabInWindow];

		// Update window controller's active tab, and update the document's isProcessing observation
		[[[tabBarControl window] windowController] updateSelectedTableDocument];
		[draggedDocument removeObserver:[draggedFromWindow windowController] forKeyPath:@"isProcessing"];
		[[[tabBarControl window] windowController] _updateProgressIndicatorForItem:tabViewItem];
	}

	// Check the window and move it to front if it's key (eg for new window creation)
    if ([[tabBarControl window] isKeyWindow]) {
        [[tabBarControl window] orderFront:self];
    }

	// workaround bug where "source list" table views are broken in the new window. See https://github.com/sequelpro/sequelpro/issues/2863
	SPWindowController *newWindowController = tabBarControl.window.windowController;
	newWindowController.selectedTableDocument.connectionController.favoritesOutlineView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
	newWindowController.selectedTableDocument.dbTablesTableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0)), dispatch_get_main_queue(), ^{
		newWindowController.selectedTableDocument.dbTablesTableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleSourceList;
		newWindowController.selectedTableDocument.connectionController.favoritesOutlineView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleSourceList;
	});
}

/**
 * Respond to dragging events entering the tab in the tab bar.
 * Allows custom behaviours - for example, if dragging text, switch to the custom
 * query view.
 */
- (void)draggingEvent:(id <NSDraggingInfo>)dragEvent enteredTabBar:(PSMTabBarControl *)tabBarControl tabView:(NSTabViewItem *)tabViewItem
{
	SPDatabaseDocument *theDocument = [tabViewItem databaseDocument];

	if (![theDocument isCustomQuerySelected] && [[[dragEvent draggingPasteboard] types] indexOfObject:NSStringPboardType] != NSNotFound)
	{
		[theDocument viewQuery:self];
	}
}

/**
 * Show tooltip for a tab view item.
 */
- (NSString *)tabView:(NSTabView *)aTabView toolTipForTabViewItem:(NSTabViewItem *)tabViewItem
{
	NSInteger tabIndex = [self.tabView indexOfTabViewItem:tabViewItem];

	if ([[self.tabBarControl cells] count] < (NSUInteger)tabIndex) return @"";

	PSMTabBarCell *theCell = [[self.tabBarControl cells] objectAtIndex:tabIndex];

	// If cell is selected show tooltip if truncated only
	if ([theCell tabState] & PSMTab_SelectedMask) {

		CGFloat cellWidth = [theCell width];
		CGFloat titleWidth = [theCell stringSize].width;
		CGFloat closeButtonWidth = 0;

		if ([theCell hasCloseButton])
			closeButtonWidth = [theCell closeButtonRectForFrame:[theCell frame]].size.width;

		if (titleWidth > cellWidth - closeButtonWidth) {
			return [theCell title];
		}

		return @"";
	}
	// if cell is not selected show full title plus MySQL version is enabled as tooltip
	else {
		return [[tabViewItem databaseDocument] tabTitleForTooltip];
	}
}

/**
 * Allow window closing of the last tab item.
 */
- (void)tabView:(NSTabView *)aTabView closeWindowForLastTabViewItem:(NSTabViewItem *)tabViewItem
{
	[[aTabView window] close];
}

/**
 * When dragging a tab off a tab bar, add a shadow to the drag window.
 */
- (void)tabViewDragWindowCreated:(NSWindow *)dragWindow
{
	[dragWindow setHasShadow:YES];
}

/**
 * Allow dragging and dropping of tabs to any position, including out of a tab bar
 * to create a new window.
 */
- (BOOL)tabView:(NSTabView*)aTabView shouldDropTabViewItem:(NSTabViewItem *)tabViewItem inTabBar:(PSMTabBarControl *)tabBarControl
{
	return YES;
}

/**
 * When a tab is dragged off a tab bar, create a new window containing a new
 * (empty) tab bar to hold it.
 */
- (PSMTabBarControl *)tabView:(NSTabView *)aTabView newTabBarForDraggedTabViewItem:(NSTabViewItem *)tabViewItem atPoint:(NSPoint)point {
	// Create the new window controller, with no tabs
    SPWindowController *newWindowController = [[SPWindowController alloc] initWithWindowNibName:@"MainWindow"];
    [self.delegate windowControllerDidCreateNewWindowController:newWindowController];
	NSWindow *newWindow = [newWindowController window];

	CGFloat toolbarHeight = 0;

	if ([[[self window] toolbar] isVisible]) {
		NSRect innerFrame = [NSWindow contentRectForFrameRect:[[self window] frame] styleMask:[[self window] styleMask]];
		toolbarHeight = innerFrame.size.height - [[[self window] contentView] frame].size.height;
	}

	// Adjust the positioning as appropriate
	point.y += toolbarHeight + kPSMTabBarControlHeight;

	// Set the new window position and size
	NSRect targetWindowFrame = [[self window] frame];
	targetWindowFrame.size.height -= toolbarHeight;
	[newWindow setFrame:targetWindowFrame display:NO];
	[newWindow setFrameTopLeftPoint:point];

	// Set the window controller as the window's delegate
	[newWindow setDelegate:newWindowController];

	// Set window title
	[newWindow setTitle:[[[tabViewItem databaseDocument] parentWindowControllerWindow] title]];

	// Return the window's tab bar
	return newWindowController.tabBarControl;
}

/**
 * When dragging a tab off the tab bar, return an image so that a
 * drag placeholder can be displayed.
 */
- (NSImage *)tabView:(NSTabView *)aTabView imageForTabViewItem:(NSTabViewItem *)tabViewItem offset:(NSSize *)offset styleMask:(NSUInteger *)styleMask
{
	NSImage *viewImage = [[NSImage alloc] init];

	// Capture an image of the entire window
	CGImageRef windowImage = CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, (unsigned int)[[self window] windowNumber], kCGWindowImageBoundsIgnoreFraming);
	NSBitmapImageRep *viewRep = [[NSBitmapImageRep alloc] initWithCGImage:windowImage];
	[viewRep setSize:[[self window] frame].size];
	[viewImage addRepresentation:viewRep];

	// Calculate the titlebar+toolbar height
	CGFloat contentViewOffsetY = [[self window] frame].size.height - [[[self window] contentView] frame].size.height;
	offset->height = contentViewOffsetY + [self.tabBarControl frame].size.height;

	// Draw over the tab bar area
	[viewImage lockFocus];
	[[NSColor windowBackgroundColor] set];
	NSRectFill([self.tabBarControl frame]);
	[viewImage unlockFocus];

	// Draw the tab bar background in the tab bar area
	[viewImage lockFocus];
	NSRect tabFrame = [self.tabBarControl frame];
	[[NSColor windowBackgroundColor] set];
	NSRectFill(tabFrame);

	// Draw the background flipped, which is actually the right way up
	NSAffineTransform *transform = [NSAffineTransform transform];

	[transform translateXBy:0.0f yBy:[[[self window] contentView] frame].size.height];
	[transform scaleXBy:1.0f yBy:-1.0f];

	[transform concat];
	[(id <PSMTabStyle>)[(PSMTabBarControl *)[aTabView delegate] style] drawBackgroundInRect:tabFrame];

	[viewImage unlockFocus];

	return viewImage;
}

/**
 * Displays the current tab's context menu.
 */
- (NSMenu *)tabView:(NSTabView *)aTabView menuForTabViewItem:(NSTabViewItem *)tabViewItem
{
	NSMenu *menu = [[NSMenu alloc] init];

	[menu addItemWithTitle:NSLocalizedString(@"Close Tab", @"close tab context menu item") action:@selector(closeTab:) keyEquivalent:@""];
	[menu insertItem:[NSMenuItem separatorItem] atIndex:1];
	[menu addItemWithTitle:NSLocalizedString(@"Open in New Tab", @"open connection in new tab context menu item") action:@selector(openDatabaseInNewTab:) keyEquivalent:@""];

	return menu;
}

/**
 * When tab drags start, show all the tab bars.  This allows adding tabs to windows
 * containing only one tab - where the bar is normally hidden.
 */
- (void)tabDragStarted:(id)sender {
    
}

/**
 * When tab drags stop, set tab bars to automatically hide again for only one tab.
 */
- (void)tabDragStopped:(id)sender {

}

#pragma mark -

- (void)dealloc {
	[self _switchOutSelectedTableDocument:nil];
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	
	[NSObject cancelPreviousPerformRequestsWithTarget:self];
}

@end
