//! Shell data/format helpers — kernel framebuffer rendering path.

const builtin_apps_mod = @import("builtin_apps.zig");
const explorer_format_mod = @import("explorer_format.zig");
const explorer_state_mod = @import("explorer_state.zig");
const explorer_context_menu_mod = @import("explorer_context_menu.zig");
const explorer_command_bar_mod = @import("explorer_command_bar.zig");
const explorer_nav_pane_mod = @import("explorer_nav_pane.zig");
const explorer_details_view_mod = @import("explorer_details_view.zig");
const explorer_view_modes_mod = @import("explorer_view_modes.zig");
const explorer_selection_mod = @import("explorer_selection.zig");
const explorer_search_mod = @import("explorer_search.zig");
const explorer_status_bar_mod = @import("explorer_status_bar.zig");
const explorer_file_ops_mod = @import("explorer_file_ops.zig");
const explorer_panes_mod = @import("explorer_panes.zig");
const explorer_shortcuts_mod = @import("explorer_shortcuts.zig");
const explorer_fs_mod = @import("explorer_fs_integration.zig");
const desktop_icons_mod = @import("desktop_icons.zig");
const drag_state_mod = @import("drag_state.zig");
const classic_shell_mod = @import("classic_shell.zig");
const taskbar_mod = @import("../taskbar/root.zig");

pub const builtin_apps = builtin_apps_mod;
pub const explorer_format = explorer_format_mod;
pub const explorer_state = explorer_state_mod;
pub const explorer_context_menu = explorer_context_menu_mod;
pub const explorer_command_bar = explorer_command_bar_mod;
pub const explorer_nav_pane = explorer_nav_pane_mod;
pub const explorer_details_view = explorer_details_view_mod;
pub const explorer_view_modes = explorer_view_modes_mod;
pub const explorer_selection = explorer_selection_mod;
pub const drag_state = drag_state_mod;
pub const classic_shell = classic_shell_mod;
pub const taskbar = taskbar_mod;

// Re-export explorer state functions
pub const explorerCanNavigateBack = explorer_state_mod.explorerCanNavigateBack;
pub const explorerCanNavigateForward = explorer_state_mod.explorerCanNavigateForward;
pub const explorerCanNavigateUp = explorer_state_mod.explorerCanNavigateUp;
pub const explorerNavigateBack = explorer_state_mod.explorerNavigateBack;
pub const explorerNavigateForward = explorer_state_mod.explorerNavigateForward;
pub const explorerNavigateUp = explorer_state_mod.explorerNavigateUp;
pub const explorerNavigateToSubdirectory = explorer_state_mod.explorerNavigateToSubdirectory;
pub const explorerHasSubdirectory = explorer_state_mod.explorerHasSubdirectory;
pub const getExplorerSubdirectoryPath = explorer_state_mod.getExplorerSubdirectoryPath;
pub const getExplorerView = explorer_state_mod.getExplorerView;
pub const setExplorerView = explorer_state_mod.setExplorerView;
pub const getExplorerLocation = explorer_state_mod.getExplorerLocation;
pub const getExplorerListSelectedRow = explorer_state_mod.getExplorerListSelectedRow;
pub const setExplorerListSelectedRow = explorer_state_mod.setExplorerListSelectedRow;
pub const getExplorerComputerDriveSelected = explorer_state_mod.getExplorerComputerDriveSelected;
pub const setExplorerComputerDriveSelected = explorer_state_mod.setExplorerComputerDriveSelected;
pub const clearExplorerSelection = explorer_state_mod.clearExplorerSelection;
pub const explorerEnsureVolumeSnapshot = explorer_state_mod.explorerEnsureVolumeSnapshot;
pub const explorerVolumes = explorer_state_mod.explorerVolumes;
pub const explorerVolumeByLetter = explorer_state_mod.explorerVolumeByLetter;
pub const readExplorerDriveRootSorted = explorer_state_mod.readExplorerDriveRootSorted;
pub const readExplorerSubdirectorySorted = explorer_state_mod.readExplorerSubdirectorySorted;
pub const getExplorerSelectedEntry = explorer_state_mod.getExplorerSelectedEntry;
pub const getExplorerSelectedEntrySize = explorer_state_mod.getExplorerSelectedEntrySize;
pub const getExplorerAddressBarKind = explorer_state_mod.getExplorerAddressBarKind;
pub const getExplorerAddressDriveLetter = explorer_state_mod.getExplorerAddressDriveLetter;
pub const explorerGetCurrentLibrary = explorer_state_mod.explorerGetCurrentLibrary;
pub const explorerIsLibraryDetailActive = explorer_state_mod.explorerIsLibraryDetailActive;
pub const explorerNavigateToLibrary = explorer_state_mod.explorerNavigateToLibrary;
pub const explorerCloseLibraryDetail = explorer_state_mod.explorerCloseLibraryDetail;
pub const getExplorerTitleSubline = explorer_state_mod.getExplorerTitleSubline;
pub const getExplorerSortField = explorer_state_mod.getExplorerSortField;
pub const getExplorerSortOrder = explorer_state_mod.getExplorerSortOrder;
pub const setExplorerSortField = explorer_state_mod.setExplorerSortField;
pub const getExplorerViewMode = explorer_state_mod.getExplorerViewMode;
pub const setExplorerViewMode = explorer_state_mod.setExplorerViewMode;
pub const getExplorerContextMenuKind = explorer_state_mod.getExplorerContextMenuKind;
pub const setExplorerContextMenuKind = explorer_state_mod.setExplorerContextMenuKind;
pub const clearExplorerContextMenu = explorer_state_mod.clearExplorerContextMenu;
pub const ExplorerSortField = explorer_state_mod.ExplorerSortField;
pub const ExplorerViewMode = explorer_state_mod.ExplorerViewMode;
pub const ExplorerContextMenuKind = explorer_state_mod.ExplorerContextMenuKind;
pub const ExplorerLibraryKind = explorer_state_mod.ExplorerLibraryKind;
pub const ExplorerSubdirectoryPath = explorer_state_mod.ExplorerSubdirectoryPath;

// Re-export explorer context menu functions
pub const showExplorerContextMenu = explorer_context_menu_mod.showExplorerContextMenu;
pub const hideExplorerContextMenu = explorer_context_menu_mod.hideExplorerContextMenu;
pub const isExplorerContextMenuVisible = explorer_context_menu_mod.isExplorerContextMenuVisible;
pub const renderExplorerContextMenu = explorer_context_menu_mod.renderExplorerContextMenu;
pub const isInsideExplorerContextMenu = explorer_context_menu_mod.isInsideExplorerContextMenu;
pub const updateExplorerContextMenuHover = explorer_context_menu_mod.updateExplorerContextMenuHover;
pub const getExplorerContextMenuClickResult = explorer_context_menu_mod.getExplorerContextMenuClickResult;
pub const updateExplorerContextMenuAnimation = explorer_context_menu_mod.updateExplorerContextMenuAnimation;
pub const ContextMenuItem = explorer_context_menu_mod.ContextMenuItem;
pub const getExplorerContextMenuHoverItem = explorer_context_menu_mod.getExplorerContextMenuHoverItem;
pub const allProgramsCount = builtin_apps_mod.allProgramsCount;
pub const allProgramsId = builtin_apps_mod.allProgramsId;
pub const pollKeyboardToFocused = builtin_apps_mod.pollKeyboardToFocused;
pub const anyWindowOpen = builtin_apps_mod.anyWindowOpen;
pub const topDraggedWindowRect = builtin_apps_mod.topDraggedWindowRect;
pub const launch = builtin_apps_mod.launch;
pub const titleOf = builtin_apps_mod.titleOf;
pub const BuiltinAppId = builtin_apps_mod.BuiltinAppId;
pub const ShellRect = builtin_apps_mod.ShellRect;
pub const RenderMode = builtin_apps_mod.RenderMode;
pub const renderShellHostedApps = builtin_apps_mod.renderShellHostedApps;
pub const getClipboard = builtin_apps_mod.getClipboard;
pub const onMouseMove = builtin_apps_mod.onMouseMove;
pub const handleClick = builtin_apps_mod.handleClick;
pub const updateCaptionHover = builtin_apps_mod.updateCaptionHover;
pub const captionHoverForTopmost = builtin_apps_mod.captionHoverForTopmost;
pub const onMouseRelease = builtin_apps_mod.onMouseRelease;
pub const isDragging = builtin_apps_mod.isDragging;
pub const advanceBuiltinDragPrev = builtin_apps_mod.advanceBuiltinDragPrev;
pub const getDragState = builtin_apps_mod.getDragState;
pub const openSlotsBoundsUnion = builtin_apps_mod.openSlotsBoundsUnion;
pub const ResizeEdge = drag_state_mod.ResizeEdge;
pub const hitTestFrameResizeEdge = drag_state_mod.hitTestFrameResizeEdge;
pub const clampShellFrameToWorkArea = drag_state_mod.clampShellFrameToWorkArea;
pub const formatAddressBar = explorer_format_mod.formatAddressBar;
pub const formatAddressBarWithSubpath = explorer_format_mod.formatAddressBarWithSubpath;

// Re-export nav pane functions
pub const renderNavigationPane = explorer_nav_pane_mod.renderNavigationPane;
pub const getNavPaneWidth = explorer_nav_pane_mod.getNavPaneWidth;
pub const setNavPaneWidth = explorer_nav_pane_mod.setNavPaneWidth;
pub const getNavHoverIndex = explorer_nav_pane_mod.getNavHoverIndex;
pub const setNavHoverIndex = explorer_nav_pane_mod.setNavHoverIndex;
pub const hitTestNavigationPane = explorer_nav_pane_mod.hitTestNavigationPane;
pub const getNavNodeAtPoint = explorer_nav_pane_mod.getNavNodeAtPoint;
pub const handleNavNodeClick = explorer_nav_pane_mod.handleNavNodeClick;
pub const handleNavChevronClick = explorer_nav_pane_mod.handleNavChevronClick;
pub const isNavNodeExpanded = explorer_nav_pane_mod.isNavNodeExpanded;
pub const toggleNavNodeExpanded = explorer_nav_pane_mod.toggleNavNodeExpanded;
pub const isNavResizeZone = explorer_nav_pane_mod.isInNavResizeZone;
pub const NavNode = explorer_nav_pane_mod.NavNode;
pub const NavNodeKind = explorer_nav_pane_mod.NavNodeKind;

// Re-export details view functions
pub const renderDetailsView = explorer_details_view_mod.renderDetailsView;
pub const getDetailColumnCount = explorer_details_view_mod.getDetailColumnCount;
pub const getDetailColumn = explorer_details_view_mod.getDetailColumn;
pub const getDetailSortColumn = explorer_details_view_mod.getDetailSortColumn;
pub const getDetailSortAscending = explorer_details_view_mod.getDetailSortAscending;
pub const sortDetailsByColumn = explorer_details_view_mod.sortDetailsByColumn;
pub const hitTestDetailsHeader = explorer_details_view_mod.hitTestDetailsHeader;
pub const getDetailRowAtPoint = explorer_details_view_mod.getDetailRowAtPoint;
pub const DetailColumn = explorer_details_view_mod.DetailColumn;
pub const DetailColumnKind = explorer_details_view_mod.DetailColumnKind;

// Re-export view modes functions
pub const renderExplorerItemsByViewMode = explorer_view_modes_mod.renderExplorerItemsByViewMode;
pub const hitTestIconView = explorer_view_modes_mod.hitTestIconView;
pub const calculateTotalHeight = explorer_view_modes_mod.calculateTotalHeight;
// Note: ExplorerViewMode is already exported from explorer_state_mod

// Re-export selection functions
pub const clearSelection = explorer_selection_mod.clearSelection;
pub const isSelected = explorer_selection_mod.isSelected;
pub const addToSelection = explorer_selection_mod.addToSelection;
pub const removeFromSelection = explorer_selection_mod.removeFromSelection;
pub const toggleSelection = explorer_selection_mod.toggleSelection;
pub const selectOnly = explorer_selection_mod.selectOnly;
pub const selectRange = explorer_selection_mod.selectRange;
pub const selectAll = explorer_selection_mod.selectAll;
pub const getSelectionCount = explorer_selection_mod.getSelectionCount;
pub const getSelectedIndices = explorer_selection_mod.getSelectedIndices;
pub const hasSelection = explorer_selection_mod.hasSelection;
pub const handleItemClick = explorer_selection_mod.handleItemClick;
pub const navigateSelection = explorer_selection_mod.navigateSelection;
pub const SelectionDirection = explorer_selection_mod.SelectionDirection;
pub const getSelectionMode = explorer_selection_mod.getSelectionMode;

// Re-export search functions
pub const filterEntriesBySearch = explorer_search_mod.filterEntriesBySearch;
pub const getFilteredIndices = explorer_search_mod.getFilteredIndices;
pub const getFilteredCount = explorer_search_mod.getFilteredCount;
pub const isSearchActive = explorer_search_mod.isSearchActive;
pub const setSearchFocused = explorer_search_mod.setSearchFocused;
pub const isSearchFocused = explorer_search_mod.isSearchFocused;
pub const getSearchText = explorer_search_mod.getSearchText;
pub const setSearchText = explorer_search_mod.setSearchText;
pub const appendSearchChar = explorer_search_mod.appendSearchChar;
pub const deleteSearchChar = explorer_search_mod.deleteSearchChar;
pub const clearSearch = explorer_search_mod.clearSearch;
pub const addToSearchHistory = explorer_search_mod.addToSearchHistory;
pub const getSearchHistory = explorer_search_mod.getSearchHistory;
pub const renderSearchBox = explorer_search_mod.renderSearchBox;
pub const renderSearchHistoryDropdown = explorer_search_mod.renderSearchHistoryDropdown;
pub const isInSearchBox = explorer_search_mod.isInSearchBox;
pub const isInClearButton = explorer_search_mod.isInClearButton;

// Re-export status bar functions
pub const renderStatusBar = explorer_status_bar_mod.renderStatusBar;
pub const updateItemCount = explorer_status_bar_mod.updateItemCount;
pub const updateSelectedCount = explorer_status_bar_mod.updateSelectedCount;
pub const updateSpaceInfo = explorer_status_bar_mod.updateSpaceInfo;
pub const setStatusMode = explorer_status_bar_mod.setStatusMode;
pub const StatusInfo = explorer_status_bar_mod.StatusInfo;
pub const getStatusInfo = explorer_status_bar_mod.getStatusInfo;

// Re-export file operations functions
pub const startDrag = explorer_file_ops_mod.startDrag;
pub const updateDrag = explorer_file_ops_mod.updateDrag;
pub const endDrag = explorer_file_ops_mod.endDrag;
pub const cancelDrag = explorer_file_ops_mod.cancelDrag;
pub const renderDragGhost = explorer_file_ops_mod.renderDragGhost;
pub const isFileDragging = explorer_file_ops_mod.isDragging;
pub const startRename = explorer_file_ops_mod.startRename;
pub const isRenameActive = explorer_file_ops_mod.isRenameActive;
pub const commitRename = explorer_file_ops_mod.commitRename;
pub const cancelRename = explorer_file_ops_mod.cancelRename;
pub const renderRenameOverlay = explorer_file_ops_mod.renderRenameOverlay;
pub const copyToClipboard = explorer_file_ops_mod.copyToClipboard;
pub const cutToClipboard = explorer_file_ops_mod.cutToClipboard;
pub const hasClipboardContent = explorer_file_ops_mod.hasClipboardContent;
pub const getExplorerDragState = explorer_file_ops_mod.getDragState;

// Re-export panes functions
pub const togglePreviewPane = explorer_panes_mod.togglePreviewPane;
pub const isPreviewPaneVisible = explorer_panes_mod.isPreviewPaneVisible;
pub const toggleDetailsPane = explorer_panes_mod.toggleDetailsPane;
pub const isDetailsPaneVisible = explorer_panes_mod.isDetailsPaneVisible;
pub const renderPreviewPane = explorer_panes_mod.renderPreviewPane;
pub const renderDetailsPane = explorer_panes_mod.renderDetailsPane;

// Re-export shortcuts functions
pub const handleExplorerKey = explorer_shortcuts_mod.handleExplorerKey;
pub const setCtrlPressed = explorer_shortcuts_mod.setCtrlPressed;
pub const setShiftPressed = explorer_shortcuts_mod.setShiftPressed;
pub const setAltPressed = explorer_shortcuts_mod.setAltPressed;
pub const VirtualKey = explorer_shortcuts_mod.VirtualKey;

// Re-export file system integration functions
pub const detectFileCategory = explorer_fs_mod.detectFileCategory;
pub const getFileTypeDescription = explorer_fs_mod.getFileTypeDescription;
pub const calculateFolderSize = explorer_fs_mod.calculateFolderSize;
pub const traverseDirectory = explorer_fs_mod.traverseDirectory;
pub const FileCategory = explorer_fs_mod.FileCategory;

// Re-export desktop icons functions
pub const initDesktopIcons = desktop_icons_mod.initDesktopIcons;
pub const renderAllDesktopIcons = desktop_icons_mod.renderAllDesktopIcons;
pub const hitTestDesktopIcon = desktop_icons_mod.hitTestDesktopIcon;
pub const handleDesktopIconClick = desktop_icons_mod.handleDesktopIconClick;
pub const iconKindFromId = desktop_icons_mod.iconKindFromId;
pub const startDesktopDrag = desktop_icons_mod.startDesktopDrag;
pub const endDesktopDrag = desktop_icons_mod.endDesktopDrag;
pub const isDesktopDragging = desktop_icons_mod.isDesktopDragging;
pub const moveDesktopIcon = desktop_icons_mod.moveDesktopIcon;
pub const startDesktopIconRename = desktop_icons_mod.startDesktopIconRename;
pub const isDesktopRenameActive = desktop_icons_mod.isDesktopRenameActive;
pub const commitDesktopRename = desktop_icons_mod.commitDesktopRename;
pub const cancelDesktopRename = desktop_icons_mod.cancelDesktopRename;
pub const renderDesktopRenameOverlay = desktop_icons_mod.renderDesktopRenameOverlay;
pub const renderDesktopIcon = desktop_icons_mod.renderDesktopIcon;
