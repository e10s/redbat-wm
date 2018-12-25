import std.exception : enforce;
import std.experimental.logger;
import xcb.xcb;

void main()
{
    int screenNum;
    auto connection = xcb_connect(":1", &screenNum); // Test on :1
    enforce(xcb_connection_has_error(connection) == 0, "Failed to connect");

    scope (exit)
    {
        xcb_disconnect(connection);
    }

    auto screen = screenOfDisplay(connection, screenNum);
    enforce(screen !is null, "Screen is null");

    immutable rootWindow = screen.root;
    immutable uint mask = XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT;
    auto cookie = xcb_change_window_attributes_checked(connection, rootWindow, XCB_CW_EVENT_MASK, &mask);
    enforce(xcb_request_check(connection, cookie) is null, "Another wm is running");

    xcb_flush(connection);

    infof("Successfully obtained root window of %#x", rootWindow);
}

xcb_screen_t* screenOfDisplay(xcb_connection_t* connection, int screen)
{
    auto iter = xcb_setup_roots_iterator(xcb_get_setup(connection));
    for (; iter.rem; --screen, xcb_screen_next(&iter))
    {
        if (screen == 0)
        {
            return iter.data;
        }
    }

    return null;
}
