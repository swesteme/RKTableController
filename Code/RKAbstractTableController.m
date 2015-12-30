//
//  RKAbstractTableController.m
//  RestKit
//
//  Created by Jeff Arena on 8/11/11.
//  Copyright (c) 2009-2012 RestKit. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "RKAbstractTableController.h"
#import "RKAbstractTableController_Internals.h"
#import "UIView+FindFirstResponder.h"
#import "RKRefreshGestureRecognizer.h"
#import "RKTableSection.h"

// Define logging component
#undef RKLogComponent
#define RKLogComponent RKlcl_cRestKitUI

/**
 Bounce pixels define how many pixels the cell swipe view is
 moved during the bounce animation
 */
#define BOUNCE_PIXELS 5.0

NSString * const RKTableControllerDidStartLoadNotification = @"RKTableControllerDidStartLoadNotification";
NSString * const RKTableControllerDidFinishLoadNotification = @"RKTableControllerDidFinishLoadNotification";
NSString * const RKTableControllerDidLoadObjectsNotification = @"RKTableControllerDidLoadObjectsNotification";
NSString * const RKTableControllerDidLoadEmptyNotification = @"RKTableControllerDidLoadEmptyNotification";
NSString * const RKTableControllerDidLoadErrorNotification = @"RKTableControllerDidLoadErrorNotification";
NSString * const RKTableControllerDidBecomeOnline = @"RKTableControllerDidBecomeOnline";
NSString * const RKTableControllerDidBecomeOffline = @"RKTableControllerDidBecomeOffline";

static NSString *lastUpdatedDateDictionaryKey = @"lastUpdatedDateDictionaryKey";

static inline NSString * RKStringFromBool(BOOL boolValue) { return boolValue ? @"YES" : @"NO"; }

NSString * RKStringFromTableControllerState(RKTableControllerState state)
{
    BOOL isLoaded = (state & RKTableControllerStateNotYetLoaded) == 0;
    BOOL isEmpty = (state & RKTableControllerStateEmpty);
    BOOL isOffline = (state & RKTableControllerStateOffline);
    BOOL isLoading = (state & RKTableControllerStateLoading);
    BOOL isError = (state & RKTableControllerStateError);

    return [NSString stringWithFormat:@"isLoaded=%@, isEmpty=%@, isOffline=%@, isLoading=%@, isError=%@, isNormal=%@",
            RKStringFromBool(isLoaded), RKStringFromBool(isEmpty), RKStringFromBool(isOffline),
            RKStringFromBool(isLoading), RKStringFromBool(isError), RKStringFromBool(state == RKTableControllerStateNormal)];
}

NSString * RKStringDescribingTransitionFromTableControllerStateToState(RKTableControllerState oldState, RKTableControllerState newState)
{
    BOOL loadedChanged = ((oldState ^ newState) & RKTableControllerStateNotYetLoaded);
    BOOL emptyChanged = ((oldState ^ newState) & RKTableControllerStateEmpty);
    BOOL offlineChanged = ((oldState ^ newState) & RKTableControllerStateOffline);
    BOOL loadingChanged = ((oldState ^ newState) & RKTableControllerStateLoading);
    BOOL errorChanged = ((oldState ^ newState) & RKTableControllerStateError);
    BOOL normalChanged = (oldState == RKTableControllerStateNormal || newState == RKTableControllerStateNormal) && (oldState != newState);

    NSMutableArray *changeDescriptions = [NSMutableArray new];
    if (loadedChanged) [changeDescriptions addObject:[NSString stringWithFormat:@"isLoaded=%@", RKStringFromBool((newState & RKTableControllerStateNotYetLoaded) == 0)]];
    if (emptyChanged) [changeDescriptions addObject:[NSString stringWithFormat:@"isEmpty=%@", RKStringFromBool(newState & RKTableControllerStateEmpty)]];
    if (offlineChanged) [changeDescriptions addObject:[NSString stringWithFormat:@"isOffline=%@", RKStringFromBool(newState & RKTableControllerStateOffline)]];
    if (loadingChanged) [changeDescriptions addObject:[NSString stringWithFormat:@"isLoading=%@", RKStringFromBool(newState & RKTableControllerStateLoading)]];
    if (errorChanged) [changeDescriptions addObject:[NSString stringWithFormat:@"isError=%@", RKStringFromBool(newState & RKTableControllerStateError)]];
    if (normalChanged) [changeDescriptions addObject:[NSString stringWithFormat:@"isNormal=%@", RKStringFromBool(newState == RKTableControllerStateNormal)]];

    return [changeDescriptions componentsJoinedByString:@", "];
}

@interface RKAbstractTableController ()

@property (nonatomic, strong) RKKeyboardScroller *keyboardScroller;
@property (nonatomic, copy) void (^failureBlock)(NSError *error);
@property (nonatomic, strong) Class HTTPOperationClass;

@end

@implementation RKAbstractTableController

#pragma mark - Instantiation

+ (id)tableControllerWithTableView:(UITableView *)tableView
                forViewController:(UIViewController *)viewController
{
    return [[self alloc] initWithTableView:tableView viewController:viewController];
}

+ (id)tableControllerForTableViewController:(UITableViewController *)tableViewController
{
    return [self tableControllerWithTableView:tableViewController.tableView
                           forViewController:tableViewController];
}

- (id)initWithTableView:(UITableView *)tableView viewController:(UIViewController *)viewController
{
    NSAssert(tableView, @"Cannot initialize a table view model with a nil tableView");
    NSAssert(viewController, @"Cannot initialize a table view model with a nil viewController");
    self = [self init];
    if (self) {
        self.tableView = tableView;
        _viewController = viewController; // Assign directly to avoid side-effect of overloaded accessor method
        self.variableHeightRows = NO;
        self.defaultRowAnimation = UITableViewRowAnimationFade;
        self.overlayFrame = CGRectZero;
        self.showsOverlayImagesModally = YES;
    }

    return self;
}

- (id)init
{
    self = [super init];
    if (self) {
        if ([self isMemberOfClass:[RKAbstractTableController class]]) {
            @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                           reason:[NSString stringWithFormat:@"%@ is abstract. Instantiate one its subclasses instead.",
                                                   NSStringFromClass([self class])]
                                         userInfo:nil];
        }

        self.state = RKTableControllerStateNotYetLoaded;
        _cellMappings = [RKTableViewCellMappings new];

        _headerItems = [NSMutableArray new];
        _footerItems = [NSMutableArray new];
        _showsHeaderRowsWhenEmpty = YES;
        _showsFooterRowsWhenEmpty = YES;

        // Setup key-value observing
        [self addObserver:self
               forKeyPath:@"state"
                  options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld
                  context:nil];
        [self addObserver:self
               forKeyPath:@"error"
                  options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld
                  context:nil];
    }
    return self;
}

- (void)dealloc
{
    // Disconnect from the tableView
    if (_tableView.delegate == self) _tableView.delegate = nil;
    if (_tableView.dataSource == self) _tableView.dataSource = nil;

    // Remove overlay and pull-to-refresh subviews
    [_stateOverlayImageView removeFromSuperview];
    [_tableOverlayView removeFromSuperview];

    // Remove observers
    [self removeObserver:self forKeyPath:@"state"];
    [self removeObserver:self forKeyPath:@"error"];
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    self.objectRequestOperation = nil;
}

- (void)setTableView:(UITableView *)tableView
{
    NSAssert(tableView, @"Cannot assign a nil tableView to the model");
    _tableView = tableView;
    _tableView.delegate = self;
    _tableView.dataSource = self;
}

- (void)setViewController:(UIViewController *)viewController
{
    if ([viewController isKindOfClass:[UITableViewController class]]) {
        self.tableView = [(UITableViewController *)viewController tableView];
    }
}

- (void)setAutoResizesForKeyboard:(BOOL)autoResizesForKeyboard
{
    if (_autoResizesForKeyboard != autoResizesForKeyboard) {
        _autoResizesForKeyboard = autoResizesForKeyboard;
        if (_autoResizesForKeyboard) {
            self.keyboardScroller = [[RKKeyboardScroller alloc] initWithViewController:self.viewController scrollView:self.tableView];
        } else {
            self.keyboardScroller = nil;
        }
    }
}

- (void)setLoading:(BOOL)loading
{
    if (loading) {
        self.state |= RKTableControllerStateLoading;
    } else {
        self.state &= ~RKTableControllerStateLoading;
    }
}

// NOTE: The loaded flag is handled specially. When loaded becomes NO,
// we clear all other flags. In practice this should not happen outside of init.
- (void)setLoaded:(BOOL)loaded
{
    if (loaded) {
        self.state &= ~RKTableControllerStateNotYetLoaded;
    } else {
        self.state = RKTableControllerStateNotYetLoaded;
    }
}

- (void)setEmpty:(BOOL)empty
{
    if (empty) {
        self.state |= RKTableControllerStateEmpty;
    } else {
        self.state &= ~RKTableControllerStateEmpty;
    }
}

- (void)setOffline:(BOOL)offline
{
    if (offline) {
        self.state |= RKTableControllerStateOffline;
    } else {
        self.state &= ~RKTableControllerStateOffline;
    }
}

- (void)setErrorState:(BOOL)error
{
    if (error) {
        self.state |= RKTableControllerStateError;
    } else {
        self.state &= ~RKTableControllerStateError;
    }
}

- (void)setObjectRequestOperation:(RKObjectRequestOperation *)objectRequestOperation
{
    [_objectRequestOperation removeObserver:self forKeyPath:@"isExecuting"];
    [_objectRequestOperation removeObserver:self forKeyPath:@"isCancelled"];
    [_objectRequestOperation removeObserver:self forKeyPath:@"isFinished"];
    [_objectRequestOperation cancel];

    _objectRequestOperation = objectRequestOperation;

    if (_objectRequestOperation) {
        [_objectRequestOperation addObserver:self forKeyPath:@"isExecuting" options:0 context:0];
        [_objectRequestOperation addObserver:self forKeyPath:@"isCancelled" options:0 context:0];
        [_objectRequestOperation addObserver:self forKeyPath:@"isFinished" options:0 context:0];
    }
}

#pragma mark - Abstract Methods

- (BOOL)isConsideredEmpty
{
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:[NSString stringWithFormat:@"You must override %@ in a subclass", NSStringFromSelector(_cmd)]
                                 userInfo:nil];
}

- (NSUInteger)sectionCount
{
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:[NSString stringWithFormat:@"You must override %@ in a subclass", NSStringFromSelector(_cmd)]
                                 userInfo:nil];
}

- (NSUInteger)rowCount
{
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:[NSString stringWithFormat:@"You must override %@ in a subclass", NSStringFromSelector(_cmd)]
                                 userInfo:nil];
}

- (id)objectForRowAtIndexPath:(NSIndexPath *)indexPath
{
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:[NSString stringWithFormat:@"You must override %@ in a subclass", NSStringFromSelector(_cmd)]
                                 userInfo:nil];
}

- (NSIndexPath *)indexPathForObject:(id)object
{
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:[NSString stringWithFormat:@"You must override %@ in a subclass", NSStringFromSelector(_cmd)]
                                 userInfo:nil];
}

- (NSUInteger)numberOfRowsInSection:(NSUInteger)index
{
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:[NSString stringWithFormat:@"You must override %@ in a subclass", NSStringFromSelector(_cmd)]
                                 userInfo:nil];
}

#pragma mark - Cell Mappings

- (void)mapObjectsWithClass:(Class)objectClass toTableCellsWithMapping:(RKTableViewCellMapping *)cellMapping
{
    // TODO: Should we raise an exception/throw a warning if you are doing class mapping for a type
    // that implements a cellMapping instance method? Maybe a class declaration overrides
    [_cellMappings setCellMapping:cellMapping forClass:objectClass];
}

- (void)mapObjectsWithClassName:(NSString *)objectClassName toTableCellsWithMapping:(RKTableViewCellMapping *)cellMapping
{
    [self mapObjectsWithClass:NSClassFromString(objectClassName) toTableCellsWithMapping:cellMapping];
}

- (RKTableViewCellMapping *)cellMappingForObjectAtIndexPath:(NSIndexPath *)indexPath
{
    NSAssert(indexPath, @"Cannot lookup cell mapping for object with a nil indexPath");
    id object = [self objectForRowAtIndexPath:indexPath];
    return [self.cellMappings cellMappingForObject:object];
}

- (UITableViewCell *)cellForObject:(id)object
{
    NSIndexPath *indexPath = [self indexPathForObject:object];
    return indexPath ? [self.tableView cellForRowAtIndexPath:indexPath] : nil;
}

#pragma mark - Header and Footer Rows

- (void)addHeaderRowForItem:(RKTableItem *)tableItem
{
    [_headerItems addObject:tableItem];
}

- (void)addFooterRowForItem:(RKTableItem *)tableItem
{
    [_footerItems addObject:tableItem];
}

- (void)addHeaderRowWithMapping:(RKTableViewCellMapping *)cellMapping
{
    RKTableItem *tableItem = [RKTableItem tableItem];
    tableItem.cellMapping = cellMapping;
    [self addHeaderRowForItem:tableItem];
}

- (void)addFooterRowWithMapping:(RKTableViewCellMapping *)cellMapping
{
    RKTableItem *tableItem = [RKTableItem tableItem];
    tableItem.cellMapping = cellMapping;
    [self addFooterRowForItem:tableItem];
}

- (void)removeAllHeaderRows
{
    [_headerItems removeAllObjects];
}

- (void)removeAllFooterRows
{
    [_footerItems removeAllObjects];
}

#pragma mark - UITableViewDataSource methods

- (UITableViewCell *)cellFromCellMapping:(RKTableViewCellMapping *)cellMapping
{
    RKLogTrace(@"About to dequeue reusable cell using self.reuseIdentifier=%@", cellMapping.reuseIdentifier);
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:cellMapping.reuseIdentifier];
    if (cell) {
        RKLogTrace(@"Dequeued existing cell object for reuse identifier '%@': %@", cellMapping.reuseIdentifier, cell);
    } else {
        cell = [[cellMapping.objectClass alloc] initWithStyle:cellMapping.style
                                               reuseIdentifier:cellMapping.reuseIdentifier];
        RKLogTrace(@"Failed to dequeue existing cell object for reuse identifier '%@', instantiated new cell: %@", cellMapping.reuseIdentifier, cell);
    }

    if (cellMapping.managesCellAttributes) {
        cell.accessoryType = cellMapping.accessoryType;
        cell.selectionStyle = cellMapping.selectionStyle;
    }

    // Fire the prepare callbacks
    for (void (^block)(UITableViewCell *) in cellMapping.prepareCellBlocks) {
        block(cell);
    }

    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSAssert(tableView == self.tableView, @"tableView:cellForRowAtIndexPath: invoked with inappropriate tableView: %@", tableView);
    NSAssert(indexPath, @"Cannot retrieve cell for nil indexPath");
    id mappableObject = [self objectForRowAtIndexPath:indexPath];
    NSAssert(mappableObject, @"Cannot build a tableView cell without an object");

    RKTableViewCellMapping* cellMapping = [self.cellMappings cellMappingForObject:mappableObject];
    NSAssert(cellMapping, @"Cannot build a tableView cell for object %@: No cell mapping defined for objects of type '%@'", mappableObject, NSStringFromClass([mappableObject class]));

    UITableViewCell *cell = [self cellFromCellMapping:cellMapping];
    NSAssert(cell, @"Cell mapping failed to dequeue or allocate a tableViewCell for object: %@", mappableObject);

    // Map the object state into the cell
    RKObjectMappingOperationDataSource *dataSource = [RKObjectMappingOperationDataSource new];
    RKMappingOperation* mappingOperation = [[RKMappingOperation alloc] initWithSourceObject:mappableObject destinationObject:cell mapping:cellMapping];
    mappingOperation.dataSource = dataSource;
    NSError* error = nil;
    BOOL success = [mappingOperation performMapping:&error];

    // NOTE: If there is no mapping work performed, but no error is generated then
    // we consider the operation a success. It is common for table cells to not contain
    // any dynamically mappable content (i.e. header/footer rows, banners, etc.)
    if (success == NO && error != nil) {
        RKLogError(@"Failed table cell mapping: %@", error);
    }

    if (self.onPrepareCellForObjectAtIndexPath) {
        self.onPrepareCellForObjectAtIndexPath(cell, mappableObject, indexPath);
    }

    RKLogTrace(@"%@ cellForRowAtIndexPath:%@ = %@", self, indexPath, cell);
    return cell;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    [NSException raise:@"Must be implemented in a subclass!" format:@"sectionCount must be implemented with a subclass"];
    return 0;
}

#pragma mark - UITableViewDelegate methods

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSAssert(tableView == self.tableView, @"tableView:didSelectRowAtIndexPath: invoked with inappropriate tableView: %@", tableView);
    RKLogTrace(@"%@: Row at indexPath %@ selected for tableView %@", self, indexPath, tableView);

    id object = [self objectForRowAtIndexPath:indexPath];

    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    RKTableViewCellMapping *cellMapping = [_cellMappings cellMappingForObject:object];

    // NOTE: Handle deselection first as the onSelectCell processing may result in the tableView
    // being reloaded and our instances invalidated
    if (cellMapping.deselectsRowOnSelection) {
        [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
    }

    if (cellMapping.onSelectCell) {
        cellMapping.onSelectCell();
    }

    if (cellMapping.onSelectCellForObjectAtIndexPath) {
        RKLogTrace(@"%@: Invoking onSelectCellForObjectAtIndexPath block with cellMapping %@ for object %@ at indexPath = %@", self, cell, object, indexPath);
        cellMapping.onSelectCellForObjectAtIndexPath(cell, object, indexPath);
    }

    // Table level selection callbacks
    if (self.onSelectCellForObjectAtIndexPath) {
        self.onSelectCellForObjectAtIndexPath(cell, object, indexPath);
    }

    if ([self.delegate respondsToSelector:@selector(tableController:didSelectCell:forObject:atIndexPath:)]) {
        [self.delegate tableController:self didSelectCell:cell forObject:object atIndexPath:indexPath];
    }
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSAssert(tableView == self.tableView, @"tableView:didSelectRowAtIndexPath: invoked with inappropriate tableView: %@", tableView);
    RKLogTrace(@"%@: Row at indexPath %@ deselected for tableView %@", self, indexPath, tableView);

    id object = [self objectForRowAtIndexPath:indexPath];

    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    RKTableViewCellMapping *cellMapping = [_cellMappings cellMappingForObject:object];

    if (cellMapping.onDeselectCellForObjectAtIndexPath) {
        RKLogTrace(@"%@: Invoking onDeselectCellForObjectAtIndexPath block with cellMapping %@ for object %@ at indexPath = %@", self, cell, object, indexPath);
        cellMapping.onDeselectCellForObjectAtIndexPath(cell, object, indexPath);
    }

    // Table level selection callbacks
    if (self.onDeselectCellForObjectAtIndexPath) {
        self.onDeselectCellForObjectAtIndexPath(cell, object, indexPath);
    }

    if ([self.delegate respondsToSelector:@selector(tableController:didDeselectCell:forObject:atIndexPath:)]) {
        [self.delegate tableController:self didDeselectCell:cell forObject:object atIndexPath:indexPath];
    }

}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSAssert(tableView == self.tableView, @"%@ invoked with inappropriate tableView: %@", NSStringFromSelector(_cmd), tableView);

    cell.hidden = NO;
    id mappableObject = [self objectForRowAtIndexPath:indexPath];
    RKTableViewCellMapping *cellMapping = [self.cellMappings cellMappingForObject:mappableObject];
    if (cellMapping.onCellWillAppearForObjectAtIndexPath) {
        cellMapping.onCellWillAppearForObjectAtIndexPath(cell, mappableObject, indexPath);
    }

    if (self.onWillDisplayCellForObjectAtIndexPath) {
        self.onWillDisplayCellForObjectAtIndexPath(cell, mappableObject, indexPath);
    }

    if ([self.delegate respondsToSelector:@selector(tableController:willDisplayCell:forObject:atIndexPath:)]) {
        [self.delegate tableController:self willDisplayCell:cell forObject:mappableObject atIndexPath:indexPath];
    }

    // Handle hiding header/footer rows when empty
    if ([self isEmpty]) {
        if (! self.showsHeaderRowsWhenEmpty && [_headerItems containsObject:mappableObject]) {
            cell.hidden = YES;
        }

        if (! self.showsFooterRowsWhenEmpty && [_footerItems containsObject:mappableObject]) {
            cell.hidden = YES;
        }
    } else {
        if (self.emptyItem && [self.emptyItem isEqual:mappableObject]) {
            cell.hidden = YES;
        }
    }
}

// Variable height support

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (self.variableHeightRows) {
        RKTableViewCellMapping *cellMapping = [self cellMappingForObjectAtIndexPath:indexPath];

        if (cellMapping.heightOfCellForObjectAtIndexPath) {
            id object = [self objectForRowAtIndexPath:indexPath];
            CGFloat height = cellMapping.heightOfCellForObjectAtIndexPath(object, indexPath);
            RKLogTrace(@"Variable row height configured for tableView. Height via block invocation for row at indexPath '%@' = %f", indexPath, cellMapping.rowHeight);
            return height;
        } else {
            RKLogTrace(@"Variable row height configured for tableView. Height for row at indexPath '%@' = %f", indexPath, cellMapping.rowHeight);
            return cellMapping.rowHeight;
        }
    }

    RKLogTrace(@"Uniform row height configured for tableView. Table view row height = %f", self.tableView.rowHeight);
    return self.tableView.rowHeight;
}

- (void)tableView:(UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath
{
    RKTableViewCellMapping *cellMapping = [self cellMappingForObjectAtIndexPath:indexPath];
    if (cellMapping.onTapAccessoryButtonForObjectAtIndexPath) {
        RKLogTrace(@"Found a block for tableView:accessoryButtonTappedForRowWithIndexPath: Executing...");
        UITableViewCell *cell = [self tableView:self.tableView cellForRowAtIndexPath:indexPath];
        id object = [self objectForRowAtIndexPath:indexPath];
        cellMapping.onTapAccessoryButtonForObjectAtIndexPath(cell, object, indexPath);
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath
{
    RKTableViewCellMapping *cellMapping = [self cellMappingForObjectAtIndexPath:indexPath];
    if (cellMapping.titleForDeleteButtonForObjectAtIndexPath) {
        RKLogTrace(@"Found a block for tableView:titleForDeleteConfirmationButtonForRowAtIndexPath: Executing...");
        UITableViewCell *cell = [self tableView:self.tableView cellForRowAtIndexPath:indexPath];
        id object = [self objectForRowAtIndexPath:indexPath];
        return cellMapping.titleForDeleteButtonForObjectAtIndexPath(cell, object, indexPath);
    }
    return NSLocalizedString(@"Delete", nil);
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (_canEditRows) {
        RKTableViewCellMapping *cellMapping = [self cellMappingForObjectAtIndexPath:indexPath];
        UITableViewCell *cell = [self tableView:self.tableView cellForRowAtIndexPath:indexPath];
        if (cellMapping.editingStyleForObjectAtIndexPath) {
            RKLogTrace(@"Found a block for tableView:editingStyleForRowAtIndexPath: Executing...");
            id object = [self objectForRowAtIndexPath:indexPath];
            return cellMapping.editingStyleForObjectAtIndexPath(cell, object, indexPath);
        }
        return UITableViewCellEditingStyleDelete;
    }
    return UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tableView didEndEditingRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self.delegate respondsToSelector:@selector(tableController:didEndEditing:atIndexPath:)]) {
        id object = [self objectForRowAtIndexPath:indexPath];
        [self.delegate tableController:self didEndEditing:object atIndexPath:indexPath];
    }
}

- (void)tableView:(UITableView *)tableView willBeginEditingRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self.delegate respondsToSelector:@selector(tableController:willBeginEditing:atIndexPath:)]) {
        id object = [self objectForRowAtIndexPath:indexPath];
        [self.delegate tableController:self willBeginEditing:object atIndexPath:indexPath];
    }
}

- (NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)sourceIndexPath toProposedIndexPath:(NSIndexPath *)proposedDestinationIndexPath
{
    if (_canMoveRows) {
        RKTableViewCellMapping *cellMapping = [self cellMappingForObjectAtIndexPath:sourceIndexPath];
        if (cellMapping.targetIndexPathForMove) {
            RKLogTrace(@"Found a block for tableView:targetIndexPathForMoveFromRowAtIndexPath:toProposedIndexPath: Executing...");
            UITableViewCell *cell = [self tableView:self.tableView cellForRowAtIndexPath:sourceIndexPath];
            id object = [self objectForRowAtIndexPath:sourceIndexPath];
            return cellMapping.targetIndexPathForMove(cell, object, sourceIndexPath, proposedDestinationIndexPath);
        }
    }
    return proposedDestinationIndexPath;
}

- (NSIndexPath *)tableView:(UITableView *)tableView willSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [self removeSwipeView:YES];
    return indexPath;
}

#pragma mark - Network Table Loading

- (Class)HTTPOperationClass
{
    return _HTTPOperationClass ?: [RKHTTPRequestOperation class];
}

- (id)objectRequestOperationWithRequest:(NSURLRequest *)request
{
    RKHTTPRequestOperation *requestOperation = [[[self HTTPOperationClass] alloc] initWithRequest:request];
    return [[RKObjectRequestOperation alloc] initWithHTTPRequestOperation:requestOperation responseDescriptors:self.responseDescriptors];
}

- (void)loadTableWithRequest:(NSURLRequest *)request
{
    // No valid cached response available, let's go to the network
    RKObjectRequestOperation *objectRequestOperation = [self objectRequestOperationWithRequest:request];

    if ([self.delegate respondsToSelector:@selector(tableController:willLoadTableWithObjectRequestOperation:)]) {
        [self.delegate tableController:self willLoadTableWithObjectRequestOperation:objectRequestOperation];
    }
    if (self.operationQueue) {
        [self.operationQueue addOperation:objectRequestOperation];
    } else {
        RKLogWarning(@"No operation queue configured: starting operation unqueued");
        [objectRequestOperation start];
    }

    self.request = request;
    self.objectRequestOperation = objectRequestOperation;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([keyPath isEqualToString:@"state"]) {
        // State changes trigger UI updates
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateTableViewForStateChange:change];
        });
    } else if ([keyPath isEqualToString:@"error"]) {
        [self setErrorState:(self.error != nil)];
    }

    // KVO on the request operation
    if (object == self.objectRequestOperation) {
        if ([keyPath isEqualToString:@"isExecuting"]) {
            if ([self.objectRequestOperation isExecuting]) {
                RKLogTrace(@"tableController %@ started loading.", self);
                [self didStartLoad];
            }
        } else if ([keyPath isEqualToString:@"isFinished"]) {
            if ([self.objectRequestOperation isFinished]) {
                if (self.objectRequestOperation.error) {
                    RKLogError(@"tableController %@ failed network load with error: %@", self, self.objectRequestOperation.error);
                    [self didFailLoadWithError:self.objectRequestOperation.error];
                } else {
                    if ([self.delegate respondsToSelector:@selector(tableController:didLoadTableWithObjectRequestOperation:)]) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self.delegate tableController:self didLoadTableWithObjectRequestOperation:self.objectRequestOperation];
                        });
                    }

                    [self didFinishLoad];
                }

                self.objectRequestOperation = nil;
            }

        } else if ([keyPath isEqualToString:@"isCancelled"]) {
            RKLogTrace(@"tableController %@ cancelled loading.", self);
            self.loading = NO;
            self.objectRequestOperation = nil;

            if ([self.delegate respondsToSelector:@selector(tableControllerDidCancelLoad:)]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate tableControllerDidCancelLoad:self];
                });
            }
        }
    }
}

- (void)cancelLoad
{
    [self.objectRequestOperation cancel];
}

- (void)didStartLoad
{
    self.loading = YES;
}

- (void)didFailLoadWithError:(NSError *)error
{
    self.error = error;
    [self didFinishLoad];
}

- (void)didFinishLoad
{
    self.empty = [self isConsideredEmpty];
    self.loading = [self.objectRequestOperation isExecuting]; // Mutate loading state after we have adjusted empty
    self.loaded = YES;

    if (![self isEmpty] && ![self isLoading]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:RKTableControllerDidLoadObjectsNotification object:self];
    }

    if (self.delegate && [_delegate respondsToSelector:@selector(tableControllerDidFinalizeLoad:)]) {
        [self.delegate performSelector:@selector(tableControllerDidFinalizeLoad:) withObject:self];
    }
}

#pragma mark - Table Overlay Views

- (UIImage *)imageForState:(RKTableControllerState)state
{
    switch (state) {
        case RKTableControllerStateNormal:
        case RKTableControllerStateLoading:
        case RKTableControllerStateNotYetLoaded:
            return nil;
            break;

        case RKTableControllerStateEmpty:
            return self.imageForEmpty;
            break;

        case RKTableControllerStateError:
            return self.imageForError;
            break;

        case RKTableControllerStateOffline:
            return self.imageForOffline;
            break;

        default:
            break;
    }

    return nil;
}

- (UIImage *)overlayImage
{
    return _stateOverlayImageView.image;
}

// Adds an overlay view above the table
- (void)addToOverlayView:(UIView *)view modally:(BOOL)modally
{
    if (! _tableOverlayView) {
        CGRect overlayFrame = CGRectIsEmpty(self.overlayFrame) ? self.tableView.frame : self.overlayFrame;
        _tableOverlayView = [[UIView alloc] initWithFrame:overlayFrame];
        _tableOverlayView.autoresizesSubviews = YES;
        _tableOverlayView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleBottomMargin;
        NSInteger tableIndex = [_tableView.superview.subviews indexOfObject:_tableView];
        if (tableIndex != NSNotFound) {
            [_tableView.superview addSubview:_tableOverlayView];
        }
    }

    // When modal, we enable user interaction to catch & discard events on the overlay and its subviews
    _tableOverlayView.userInteractionEnabled = modally;
    view.userInteractionEnabled = modally;

    if (CGRectIsEmpty(view.frame)) {
        view.frame = _tableOverlayView.bounds;

        // Center it in the overlay
        view.center = _tableOverlayView.center;
    }

    [_tableOverlayView addSubview:view];
}

- (void)resetOverlayView
{
    if (_stateOverlayImageView && _stateOverlayImageView.image == nil) {
        [_stateOverlayImageView removeFromSuperview];
    }
    if (_tableOverlayView && _tableOverlayView.subviews.count == 0) {
        [_tableOverlayView removeFromSuperview];
        _tableOverlayView = nil;
    }
}

- (void)addSubviewOverTableView:(UIView *)view
{
    NSInteger tableIndex = [_tableView.superview.subviews
                            indexOfObject:_tableView];
    if (NSNotFound != tableIndex) {
        [_tableView.superview addSubview:view];
    }
}

- (BOOL)removeImageFromOverlay:(UIImage *)image
{
    if (image && _stateOverlayImageView.image == image) {
        _stateOverlayImageView.image = nil;
        return YES;
    }
    return NO;
}

- (void)showImageInOverlay:(UIImage *)image
{
    if (! _stateOverlayImageView) {
        _stateOverlayImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _stateOverlayImageView.opaque = YES;
        _stateOverlayImageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleBottomMargin;
        _stateOverlayImageView.contentMode = UIViewContentModeCenter;
    }
    _stateOverlayImageView.image = image;
    [self addToOverlayView:_stateOverlayImageView modally:self.showsOverlayImagesModally];
}

- (void)removeImageOverlay
{
    _stateOverlayImageView.image = nil;
    [_stateOverlayImageView removeFromSuperview];
    [self resetOverlayView];
}

- (void)setImageForEmpty:(UIImage *)imageForEmpty
{
    BOOL imageRemoved = [self removeImageFromOverlay:_imageForEmpty];
    _imageForEmpty = imageForEmpty;
    if (imageRemoved) [self showImageInOverlay:_imageForEmpty];
}

- (void)setImageForError:(UIImage *)imageForError
{
    BOOL imageRemoved = [self removeImageFromOverlay:_imageForError];
    _imageForError = imageForError;
    if (imageRemoved) [self showImageInOverlay:_imageForError];
}

- (void)setImageForOffline:(UIImage *)imageForOffline
{
    BOOL imageRemoved = [self removeImageFromOverlay:_imageForOffline];
    _imageForOffline = imageForOffline;
    if (imageRemoved) [self showImageInOverlay:_imageForOffline];
}

- (void)setLoadingView:(UIView *)loadingView
{
    BOOL viewRemoved = (_loadingView.superview != nil);
    [_loadingView removeFromSuperview];
    [self resetOverlayView];
    _loadingView = loadingView;
    if (viewRemoved) [self addToOverlayView:_loadingView modally:NO];
}

#pragma mark - KVO & Table States

- (BOOL)isLoading
{
    return (self.state & RKTableControllerStateLoading) != 0;
}

- (BOOL)isLoaded
{
    return (self.state & RKTableControllerStateNotYetLoaded) == 0;
}

- (BOOL)isOffline
{
    return (self.state & RKTableControllerStateOffline) != 0;
}

- (BOOL)isOnline
{
    return ![self isOffline];
}

- (BOOL)isError
{
    return (self.state & RKTableControllerStateError) != 0;
}

- (BOOL)isEmpty
{
    return (self.state & RKTableControllerStateEmpty) != 0;
}

- (void)isLoadingDidChange
{
    if ([self isLoading]) {
        if ([self.delegate respondsToSelector:@selector(tableControllerDidStartLoad:)]) {
            [self.delegate tableControllerDidStartLoad:self];
        }

        [[NSNotificationCenter defaultCenter] postNotificationName:RKTableControllerDidStartLoadNotification object:self];

        // Remove the image overlay while we are loading
        [self removeImageOverlay];

        if (self.loadingView) {
            [self addToOverlayView:self.loadingView modally:NO];
        }
    } else {
        if ([self.delegate respondsToSelector:@selector(tableControllerDidFinishLoad:)]) {
            [self.delegate tableControllerDidFinishLoad:self];
        }

        [[NSNotificationCenter defaultCenter] postNotificationName:RKTableControllerDidFinishLoadNotification object:self];

        if (self.loadingView) {
            [self.loadingView removeFromSuperview];
            [self resetOverlayView];
        }

        [self resetPullToRefreshRecognizer];
    }

    // We don't want any image overlays applied until loading is finished
    _stateOverlayImageView.hidden = [self isLoading];
}

- (void)isLoadedDidChange
{
    if ([self isLoaded]) {
        RKLogDebug(@"%@: is now loaded.", self);
    } else {
        RKLogDebug(@"%@: is NOT loaded.", self);
    }
}

- (void)isErrorDidChange
{
    if ([self isError]) {
        if ([self.delegate respondsToSelector:@selector(tableController:didFailLoadWithError:)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate tableController:self didFailLoadWithError:self.error];
            });
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.failureBlock) self.failureBlock(self.error);
        });

        NSDictionary *userInfo = [NSDictionary dictionaryWithObject:self.error forKey:RKErrorNotificationErrorKey];
        [[NSNotificationCenter defaultCenter] postNotificationName:RKTableControllerDidLoadErrorNotification object:self userInfo:userInfo];
    }
}

- (void)isEmptyDidChange
{
    if ([self isEmpty]) {
        if ([self.delegate respondsToSelector:@selector(tableControllerDidBecomeEmpty:)]) {
            [self.delegate tableControllerDidBecomeEmpty:self];
        }

        [[NSNotificationCenter defaultCenter] postNotificationName:RKTableControllerDidLoadEmptyNotification object:self];
    }
}

- (void)isOnlineDidChange
{
    if ([self isOnline]) {
        // We just transitioned to online
        if ([self.delegate respondsToSelector:@selector(tableControllerDidBecomeOnline:)]) {
            [self.delegate tableControllerDidBecomeOnline:self];
        }

        [[NSNotificationCenter defaultCenter] postNotificationName:RKTableControllerDidBecomeOnline object:self];
    } else {
        // We just transitioned to offline
        if ([self.delegate respondsToSelector:@selector(tableControllerDidBecomeOffline:)]) {
            [self.delegate tableControllerDidBecomeOffline:self];
        }

        [[NSNotificationCenter defaultCenter] postNotificationName:RKTableControllerDidBecomeOffline object:self];
    }
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p %@>", self.class, self, RKStringFromTableControllerState(self.state)];
}

- (void)updateTableViewForStateChange:(NSDictionary *)change
{
    RKTableControllerState oldState = [[change valueForKey:NSKeyValueChangeOldKey] integerValue];
    RKTableControllerState newState = [[change valueForKey:NSKeyValueChangeNewKey] integerValue];

    if (oldState == newState) {
        return;
    }
    RKLogTrace(@"State Change for <%@: %p>: %@", self.class, self, RKStringDescribingTransitionFromTableControllerStateToState(oldState, newState));

    // Determine state transitions
    BOOL loadedChanged = ((oldState ^ newState) & RKTableControllerStateNotYetLoaded);
    BOOL emptyChanged = ((oldState ^ newState) & RKTableControllerStateEmpty);
    BOOL offlineChanged = ((oldState ^ newState) & RKTableControllerStateOffline);
    BOOL loadingChanged = ((oldState ^ newState) & RKTableControllerStateLoading);
    BOOL errorChanged = ((oldState ^ newState) & RKTableControllerStateError);

    if (loadedChanged) [self isLoadedDidChange];
    if (emptyChanged) [self isEmptyDidChange];
    if (offlineChanged) [self isOnlineDidChange];
    if (errorChanged) [self isErrorDidChange];
    if (loadingChanged) [self isLoadingDidChange];

    // Clear the image from the overlay
    _stateOverlayImageView.image = nil;

    // Determine the appropriate overlay image to display (if any)
    if (self.state == RKTableControllerStateNormal) {
        [self removeImageOverlay];
    } else {
        if ([self isLoading]) {
            // Don't adjust the overlay until the load has completed
            return;
        }

        // Though the table can be in more than one state, we only
        // want to display a single overlay image.
        if ([self isOffline] && self.imageForOffline) {
            [self showImageInOverlay:self.imageForOffline];
        } else if ([self isError] && self.imageForError) {
            [self showImageInOverlay:self.imageForError];
        } else if ([self isEmpty] && self.imageForEmpty) {
            [self showImageInOverlay:self.imageForEmpty];
        }
    }

    // Remove the overlay if no longer in use
    [self resetOverlayView];
}

#pragma mark - Pull to Refresh

- (RKRefreshGestureRecognizer *)pullToRefreshGestureRecognizer
{
    RKRefreshGestureRecognizer *refreshRecognizer = nil;
    for (RKRefreshGestureRecognizer *recognizer in self.tableView.gestureRecognizers) {
        if ([recognizer isKindOfClass:[RKRefreshGestureRecognizer class]]) {
            refreshRecognizer = recognizer;
            break;
        }
    }
    return refreshRecognizer;
}

- (void)setPullToRefreshEnabled:(BOOL)pullToRefreshEnabled
{
    RKRefreshGestureRecognizer *recognizer = nil;
    if (pullToRefreshEnabled) {
        recognizer = [[RKRefreshGestureRecognizer alloc] initWithTarget:self action:@selector(pullToRefreshStateChanged:)];
        [self.tableView addGestureRecognizer:recognizer];
    }
    else {
        recognizer = [self pullToRefreshGestureRecognizer];
        if (recognizer)
            [self.tableView removeGestureRecognizer:recognizer];
    }
    _pullToRefreshEnabled = pullToRefreshEnabled;
}

- (void)pullToRefreshStateChanged:(UIGestureRecognizer *)gesture
{
    // Migrated to subclass...
//    if (gesture.state == UIGestureRecognizerStateRecognized) {
//        if ([self pullToRefreshDataSourceIsLoading:gesture]) return;
//        RKLogDebug(@"%@: pull to refresh triggered from gesture: %@", self, gesture);
//        [self loadTableWithRequest:self.request];
//    }
}

- (void)resetPullToRefreshRecognizer
{
    RKRefreshGestureRecognizer *recognizer = [self pullToRefreshGestureRecognizer];
    if (recognizer)
        [recognizer setRefreshState:RKRefreshIdle];
}

- (BOOL)pullToRefreshDataSourceIsLoading:(UIGestureRecognizer *)gesture
{
    // If we have already been loaded and we are loading again, a refresh is taking place...
    return [self isLoaded] && [self isLoading] && [self isOnline];
}

- (NSDate *)lastUpdatedDate
{
    NSCachedURLResponse *cachedresponse = [[NSURLCache sharedURLCache] cachedResponseForRequest:self.request];
    NSHTTPURLResponse *response = (NSHTTPURLResponse *)[cachedresponse response];
    return [[(NSHTTPURLResponse *)response allHeaderFields] objectForKey:@"Date"];
}

- (NSDate *)pullToRefreshDataSourceLastUpdated:(UIGestureRecognizer *)gesture
{
    NSDate *dataSourceLastUpdated = [self lastUpdatedDate];
    return dataSourceLastUpdated ? dataSourceLastUpdated : [NSDate date];
}

#pragma mark - Cell Swipe Menu Methods

- (void)setupSwipeGestureRecognizers
{
    // Setup a right swipe gesture recognizer
    UISwipeGestureRecognizer *rightSwipeGestureRecognizer = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swipeRight:)];
    rightSwipeGestureRecognizer.direction = UISwipeGestureRecognizerDirectionRight;
    [self.tableView addGestureRecognizer:rightSwipeGestureRecognizer];

    // Setup a left swipe gesture recognizer
    UISwipeGestureRecognizer *leftSwipeGestureRecognizer = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swipeLeft:)];
    leftSwipeGestureRecognizer.direction = UISwipeGestureRecognizerDirectionLeft;
    [self.tableView addGestureRecognizer:leftSwipeGestureRecognizer];
}

- (void)removeSwipeGestureRecognizers
{
    for (UIGestureRecognizer *recognizer in self.tableView.gestureRecognizers) {
        if ([recognizer isKindOfClass:[UISwipeGestureRecognizer class]]) {
            [self.tableView removeGestureRecognizer:recognizer];
        }
    }
}

- (void)setCanEditRows:(BOOL)canEditRows
{
    NSAssert(!_cellSwipeViewsEnabled, @"Table model cannot be made editable when cell swipe menus are enabled");
    _canEditRows = canEditRows;
}

- (void)setCellSwipeViewsEnabled:(BOOL)cellSwipeViewsEnabled
{
    NSAssert(!_canEditRows, @"Cell swipe menus cannot be enabled for editable tableModels");
    if (cellSwipeViewsEnabled) {
        [self setupSwipeGestureRecognizers];
    } else {
        [self removeSwipeView:YES];
        [self removeSwipeGestureRecognizers];
    }
    _cellSwipeViewsEnabled = cellSwipeViewsEnabled;
}

- (void)swipe:(UISwipeGestureRecognizer *)recognizer direction:(UISwipeGestureRecognizerDirection)direction
{
    if (_cellSwipeViewsEnabled && recognizer && recognizer.state == UIGestureRecognizerStateEnded) {
        CGPoint location = [recognizer locationInView:self.tableView];
        NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:location];
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        id object = [self objectForRowAtIndexPath:indexPath];

        if (cell.frame.origin.x != 0) {
            [self removeSwipeView:YES];
            return;
        }

        [self removeSwipeView:NO];

        if (cell != _swipeCell && !_animatingCellSwipe) {
            [self addSwipeViewTo:cell withObject:object direction:direction];
        }
    }
}

- (void)swipeLeft:(UISwipeGestureRecognizer *)recognizer
{
    [self swipe:recognizer direction:UISwipeGestureRecognizerDirectionLeft];
}

- (void)swipeRight:(UISwipeGestureRecognizer *)recognizer
{
    [self swipe:recognizer direction:UISwipeGestureRecognizerDirectionRight];
}

- (void)addSwipeViewTo:(UITableViewCell *)cell withObject:(id)object direction:(UISwipeGestureRecognizerDirection)direction
{
    if (_cellSwipeViewsEnabled) {
        NSAssert(cell, @"Cannot process swipe view with nil cell");
        NSAssert(object, @"Cannot process swipe view with nil object");

        _cellSwipeView.frame = cell.frame;

        if ([self.delegate respondsToSelector:@selector(tableController:willAddSwipeView:toCell:forObject:)]) {
            [self.delegate tableController:self
                         willAddSwipeView:_cellSwipeView
                                   toCell:cell
                                forObject:object];
        }

        [self.tableView insertSubview:_cellSwipeView belowSubview:cell];

        _swipeCell = cell;
        _swipeObject = object;
        _swipeDirection = direction;

        CGRect cellFrame = cell.frame;

        _cellSwipeView.frame = CGRectMake(0, cellFrame.origin.y, cellFrame.size.width, cellFrame.size.height);

        _animatingCellSwipe = YES;
        [UIView beginAnimations:nil context:nil];
        [UIView setAnimationDuration:0.2];
        [UIView setAnimationDelegate:self];
        [UIView setAnimationDidStopSelector:@selector(animationDidStopAddingSwipeView:finished:context:)];

        cell.frame = CGRectMake(direction == UISwipeGestureRecognizerDirectionRight ? cellFrame.size.width : -cellFrame.size.width, cellFrame.origin.y, cellFrame.size.width, cellFrame.size.height);
        [UIView commitAnimations];
    }
}

- (void)animationDidStopAddingSwipeView:(NSString *)animationID finished:(NSNumber *)finished context:(void *)context
{
    _animatingCellSwipe = NO;
}

- (void)removeSwipeView:(BOOL)animated
{
    if (!_cellSwipeViewsEnabled || !_swipeCell || _animatingCellSwipe) {
        RKLogTrace(@"Exiting early with _cellSwipeViewsEnabled=%d, _swipCell=%@, _animatingCellSwipe=%d",
                   _cellSwipeViewsEnabled, _swipeCell, _animatingCellSwipe);
        return;
    }

    if ([self.delegate respondsToSelector:@selector(tableController:willRemoveSwipeView:fromCell:forObject:)]) {
        [self.delegate tableController:self
                     willRemoveSwipeView:_cellSwipeView
                            fromCell:_swipeCell
                            forObject:_swipeObject];
    }

    if (animated) {
        [UIView beginAnimations:nil context:nil];
        [UIView setAnimationDuration:0.2];
        if (_swipeDirection == UISwipeGestureRecognizerDirectionRight) {
            _swipeCell.frame = CGRectMake(BOUNCE_PIXELS, _swipeCell.frame.origin.y, _swipeCell.frame.size.width, _swipeCell.frame.size.height);
        } else {
            _swipeCell.frame = CGRectMake(-BOUNCE_PIXELS, _swipeCell.frame.origin.y, _swipeCell.frame.size.width, _swipeCell.frame.size.height);
        }
        _animatingCellSwipe = YES;
        [UIView setAnimationDelegate:self];
        [UIView setAnimationDidStopSelector:@selector(animationDidStopOne:finished:context:)];
        [UIView commitAnimations];
    } else {
        [_cellSwipeView removeFromSuperview];
        _swipeCell.frame = CGRectMake(0, _swipeCell.frame.origin.y, _swipeCell.frame.size.width, _swipeCell.frame.size.height);
        _swipeCell = nil;
    }
}

- (void)animationDidStopOne:(NSString *)animationID finished:(NSNumber *)finished context:(void *)context
{
    [UIView beginAnimations:nil context:nil];
    [UIView setAnimationDuration:0.2];
    if (_swipeDirection == UISwipeGestureRecognizerDirectionRight) {
        _swipeCell.frame = CGRectMake(BOUNCE_PIXELS*2, _swipeCell.frame.origin.y, _swipeCell.frame.size.width, _swipeCell.frame.size.height);
    } else {
        _swipeCell.frame = CGRectMake(-BOUNCE_PIXELS*2, _swipeCell.frame.origin.y, _swipeCell.frame.size.width, _swipeCell.frame.size.height);
    }
    [UIView setAnimationDelegate:self];
    [UIView setAnimationDidStopSelector:@selector(animationDidStopTwo:finished:context:)];
    [UIView setAnimationCurve:UIViewAnimationCurveLinear];
    [UIView commitAnimations];
}

- (void)animationDidStopTwo:(NSString *)animationID finished:(NSNumber *)finished context:(void *)context
{
    [UIView commitAnimations];
    [UIView beginAnimations:nil context:nil];
    [UIView setAnimationDuration:0.2];
    if (_swipeDirection == UISwipeGestureRecognizerDirectionRight) {
        _swipeCell.frame = CGRectMake(0, _swipeCell.frame.origin.y, _swipeCell.frame.size.width, _swipeCell.frame.size.height);
    } else {
        _swipeCell.frame = CGRectMake(0, _swipeCell.frame.origin.y, _swipeCell.frame.size.width, _swipeCell.frame.size.height);
    }
    [UIView setAnimationDelegate:self];
    [UIView setAnimationDidStopSelector:@selector(animationDidStopThree:finished:context:)];
    [UIView setAnimationCurve:UIViewAnimationCurveLinear];
    [UIView commitAnimations];
}

- (void)animationDidStopThree:(NSString *)animationID finished:(NSNumber *)finished context:(void *)context
{
    _animatingCellSwipe = NO;
    _swipeCell = nil;
    [_cellSwipeView removeFromSuperview];
}

#pragma mark UIScrollViewDelegate methods

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
    [self removeSwipeView:YES];
}

- (BOOL)scrollViewShouldScrollToTop:(UIScrollView *)scrollView
{
    [self removeSwipeView:NO];
    return YES;
}

- (void)reloadRowForObject:(id)object withRowAnimation:(UITableViewRowAnimation)rowAnimation
{
    NSIndexPath *indexPath = [self indexPathForObject:object];
    if (indexPath) {
        [self.tableView reloadRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:rowAnimation];
    }
}

@end
