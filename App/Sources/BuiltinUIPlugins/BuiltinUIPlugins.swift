import AssistantUI
import AttachmentsUI
import BacklinksUI
import CanvasUI
import CollectionCardsUI
import CollectionKanbanUI
import CollectionTableUI
import CollectionsUI
import DailyNotesUI
import DiagramsUI
import ExcalidrawUI
import FileExplorerUI
import FileViewersUI
import GitSyncUI
import HabitsUI
import HomeUI
import GraphUI
import MarkdownEditorUI
import MeetingsUI
import MindmapUI
import NoteInfoUI
import OutlineUI
import PluginKitUI
import QuickSwitcherUI
import SearchUI
import SoundsUI
import SqueezeUI
import TagsUI
import ProjectsUI
import TasksUI
import ImportUI
import IntroUI
import TrashUI

/// Every first-party UI plugin. The app registers this list next to the logic plugins' `builtinPlugins`
/// (the CLI only uses the latter). `BuiltinUIPluginsTests` checks whatever is added here.
///
/// `nonisolated(unsafe)` because Swift 6 cannot prove `[any Plugin.Type]` is `Sendable` (`Plugin` comes from a
/// Swift 5 module). It is a constant list of types, which hold no state, so sharing it is safe.
nonisolated(unsafe) public let builtinUIPlugins: [Plugin.Type] = [
    MarkdownEditorPlugin.self,
    FileExplorerUIPlugin.self,
    QuickSwitcherPlugin.self,
    BacklinksPlugin.self,
    OutlinePlugin.self,
    DailyNotesUIPlugin.self,
    SearchUIPlugin.self,
    HabitsUIPlugin.self,
    GraphPlugin.self,
    MindmapPlugin.self,
    TasksUIPlugin.self,
    ProjectsUIPlugin.self,
    NoteInfoPlugin.self,
    DiagramsPlugin.self,
    TrashUIPlugin.self,
    AssistantUIPlugin.self,
    AttachmentsUIPlugin.self,
    SqueezeUIPlugin.self,
    CanvasUIPlugin.self,
    GitSyncUIPlugin.self,
    CollectionsUIPlugin.self,
    CollectionTableUIPlugin.self,
    CollectionKanbanUIPlugin.self,
    CollectionCardsUIPlugin.self,
    TagsUIPlugin.self,
    FileViewersUIPlugin.self,
    HomeUIPlugin.self,
    MeetingsUIPlugin.self,
    ExcalidrawUIPlugin.self,
    ImportUIPlugin.self,
    IntroUIPlugin.self,
    SoundsUIPlugin.self,
]
