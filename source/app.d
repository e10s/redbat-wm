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

    while (true)
    {
        auto event = xcb_wait_for_event(connection);
        if (event is null)
        {
            error("I/O error");
            break;
        }

        immutable eventType = event.response_type & ~0x80;
        switch (eventType)
        {
        case XCB_MAP_REQUEST:
            infof("XCB_MAP_REQUEST %s", eventType);
            onMapRequest(connection, cast(xcb_map_request_event_t*) event);
            break;
        case XCB_CONFIGURE_REQUEST:
            infof("XCB_CONFIGURE_REQUEST %s", eventType);
            onConfigureRequest(connection, cast(xcb_configure_request_event_t*) event);
            break;
        case XCB_CIRCULATE_REQUEST:
            infof("XCB_CIRCULATE_REQUEST %s", eventType);
            // Do something
            break;
        default:
            warningf("Unknown event: %s", eventType);
            break;
        }

        import core.stdc.stdlib : free;

        free(event);
    }
}

void onMapRequest(xcb_connection_t* connection, xcb_map_request_event_t* event)
{
    xcb_map_window(connection, event.window);
    xcb_flush(connection);
}

void onConfigureRequest(xcb_connection_t* connection, xcb_configure_request_event_t* event)
{
    infof("xy = (%s, %s), wh = (%s, %s)", event.x, event.y, event.width, event.height);
    uint[] values;

    // Set values in this order!!
    if (event.value_mask & XCB_CONFIG_WINDOW_X)
    {
        values ~= event.x;
    }
    if (event.value_mask & XCB_CONFIG_WINDOW_Y)
    {
        values ~= event.y;
    }
    if (event.value_mask & XCB_CONFIG_WINDOW_WIDTH)
    {
        values ~= event.width;
    }
    if (event.value_mask & XCB_CONFIG_WINDOW_HEIGHT)
    {
        values ~= event.height;
    }
    if (event.value_mask & XCB_CONFIG_WINDOW_BORDER_WIDTH)
    {
        values ~= event.border_width;
    }
    if (event.value_mask & XCB_CONFIG_WINDOW_SIBLING)
    {
        values ~= event.sibling;
    }
    if (event.value_mask & XCB_CONFIG_WINDOW_STACK_MODE)
    {
        values ~= event.stack_mode;
    }

    xcb_configure_window(connection, event.window, event.value_mask, values.ptr);
    xcb_flush(connection);
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
