import subprocess
from collections.abc import Sequence
from typing import Any

from AppKit import NSWorkspace
from Xlib import X, display, error
from Xlib.protocol import event

from aerospace_x11.service import Direction, moved_position, resized_dimensions


class CocoaFrontmostApplication:
    def bundle_identifier(self) -> str | None:
        application: Any = NSWorkspace.sharedWorkspace().frontmostApplication()
        if application is None:
            return None
        bundle_identifier: Any = application.bundleIdentifier()
        return None if bundle_identifier is None else str(bundle_identifier)


class AerospaceCli:
    @staticmethod
    def _run(arguments: Sequence[str]) -> int:
        return subprocess.run(["aerospace", *arguments], check=False).returncode

    def move(self, direction: Direction) -> int:
        return self._run(["move", direction])

    def resize(self, delta: int) -> int:
        return self._run(["resize", "smart", f"{delta:+d}"])


class XlibWindows:
    @staticmethod
    def _active(connection: Any) -> tuple[Any, Any, Any] | None:
        root: Any = connection.screen().root
        active_window_atom: Any = connection.intern_atom("_NET_ACTIVE_WINDOW")
        active: Any = root.get_full_property(active_window_atom, X.AnyPropertyType)
        if active is None or not active.value:
            return None
        window_identifier = int(active.value[0])
        if window_identifier == 0:
            return None
        window: Any = connection.create_resource_object("window", window_identifier)
        return root, window, window.get_geometry()

    @staticmethod
    def _supports_move_resize(connection: Any, root: Any) -> bool:
        supported_atom: Any = connection.intern_atom("_NET_SUPPORTED")
        supported: Any = root.get_full_property(supported_atom, X.AnyPropertyType)
        move_resize_atom: Any = connection.intern_atom("_NET_MOVERESIZE_WINDOW")
        return supported is not None and move_resize_atom in supported.value

    @staticmethod
    def _send_move_resize(
        connection: Any,
        root: Any,
        window: Any,
        values: list[int],
    ) -> None:
        message = event.ClientMessage(
            window=window,
            client_type=connection.intern_atom("_NET_MOVERESIZE_WINDOW"),
            data=(32, values),
        )
        root.send_event(
            message,
            event_mask=X.SubstructureRedirectMask | X.SubstructureNotifyMask,
        )
        connection.flush()

    def move_active(self, display_name: str, direction: Direction) -> bool:
        try:
            connection: Any = display.Display(display_name)
            try:
                active = self._active(connection)
                if active is None:
                    return False
                root, window, _ = active
                coordinates: Any = window.translate_coords(root, 0, 0)
                x, y = moved_position(int(coordinates.x), int(coordinates.y), direction)
                if self._supports_move_resize(connection, root):
                    self._send_move_resize(
                        connection,
                        root,
                        window,
                        [(1 << 8) | (1 << 9), x, y, 0, 0],
                    )
                else:
                    window.configure(x=x, y=y)
                    connection.flush()
                return True
            finally:
                connection.close()
        except (error.DisplayConnectionError, error.XError, OSError):
            return False

    def resize_active(self, display_name: str, delta: int) -> bool:
        try:
            connection: Any = display.Display(display_name)
            try:
                active = self._active(connection)
                if active is None:
                    return False
                root, window, geometry = active
                width, height = resized_dimensions(
                    int(geometry.width),
                    int(geometry.height),
                    delta,
                )
                if self._supports_move_resize(connection, root):
                    self._send_move_resize(
                        connection,
                        root,
                        window,
                        [(1 << 10) | (1 << 11), 0, 0, width, height],
                    )
                else:
                    window.configure(width=width, height=height)
                    connection.flush()
                return True
            finally:
                connection.close()
        except (error.DisplayConnectionError, error.XError, OSError):
            return False
