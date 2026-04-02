pub const window = @import("window/window.zig");

pub const LayerSurface = @import("./LayerSurface.zig");
pub const Popup = @import("./Popup.zig");
pub const XwaylandOverride = @import("./XwaylandOverride.zig");

pub const Error = error{
    CursorNotOnOutput,
    FailedToCreateSceneTree,
    FailedToDetermineOutout,
    OutOfMemory,
    ParentSceneTreeNotFound,
    SceneTreeNotFound,
};
