import AssistantPlugin
import AttachmentsPlugin
import CapturePlugin
import CanvasPlugin
import CollectionsPlugin
import DailyNotesPlugin
import ExcalidrawPlugin
import FileExplorerPlugin
import GitSyncPlugin
import HabitTrackerPlugin
import MeetingsPlugin
import NoteGraphPlugin
import NoteQueryPlugin
import NotesImportPlugin
import ObsidianImportPlugin
import PluginKit
import ProjectsPlugin
import SqueezePlugin
import TasksPlugin
import TrashPlugin
import TruffleSearchPlugin

/// Every first-party plugin. The CLI and the app register exactly this list.
public let builtinPlugins: [Plugin.Type] = [
    NoteGraphPlugin.self,
    DailyNotesPlugin.self,
    HabitTrackerPlugin.self,
    ObsidianImportPlugin.self,
    NotesImportPlugin.self,
    TruffleSearchPlugin.self,
    FileExplorerPlugin.self,
    NoteQueryPlugin.self,
    TasksPlugin.self,
    TrashPlugin.self,
    AttachmentsPlugin.self,
    SqueezePlugin.self,
    CanvasPlugin.self,
    GitSyncPlugin.self,
    CollectionsPlugin.self,
    MeetingsPlugin.self,
    ExcalidrawPlugin.self,
    AssistantPlugin.self,
    ProjectsPlugin.self,
    CapturePlugin.self,
]
