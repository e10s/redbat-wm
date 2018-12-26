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
            onMapRequest(connection, screen, cast(xcb_map_request_event_t*) event);
            break;
        case XCB_CONFIGURE_REQUEST:
            infof("XCB_CONFIGURE_REQUEST %s", eventType);
            onConfigureRequest(connection, screen, cast(xcb_configure_request_event_t*) event);
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

xcb_window_t createFrame(xcb_connection_t* connection, xcb_screen_t* screen, short x, short y, ushort width, ushort height)
{
    auto frame = xcb_generate_id(connection);
    xcb_create_window(connection, XCB_COPY_FROM_PARENT, frame, screen.root, x, y, width, height, 3,
            XCB_WINDOW_CLASS_INPUT_OUTPUT, screen.root_visual, 0, null);
    immutable uint mask = XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT;
    xcb_change_window_attributes_checked(connection, frame, XCB_CW_EVENT_MASK, &mask);
    xcb_flush(connection);
    return frame;
}

void onMapRequest(xcb_connection_t* connection, xcb_screen_t* screen, xcb_map_request_event_t* event)
{
    auto geo = xcb_get_geometry_reply(connection, xcb_get_geometry(connection, event.window), null);
    auto frame = createFrame(connection, screen, geo.x, geo.y, cast(ushort)(geo.width + geo.border_width * 2),
            cast(ushort)(geo.height + geo.border_width * 2));
    import core.stdc.stdlib : free;

    free(geo);
    xcb_reparent_window(connection, event.window, frame, 0, 0);
    xcb_map_window(connection, frame);
    xcb_map_window(connection, event.window);
    xcb_flush(connection);
}

void onConfigureRequest(xcb_connection_t* connection, xcb_screen_t* screen, xcb_configure_request_event_t* event)
{
    infof("pw = (%#x, %#x), xy = (%s, %s), wh = (%s, %s)", event.parent, event.window, event.x, event.y, event.width, event.height);
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

    size_t popCount;
    if (event.parent != screen.root)
    { // event for frame
        xcb_configure_window(connection, event.parent, event.value_mask, values.ptr);

        // No need to move the child within its frame
        if (event.value_mask & XCB_CONFIG_WINDOW_X)
        {
            event.value_mask |= ~XCB_CONFIG_WINDOW_X;
            popCount++;
        }
        if (event.value_mask & XCB_CONFIG_WINDOW_Y)
        {
            event.value_mask |= ~XCB_CONFIG_WINDOW_Y;
            popCount++;
        }
    }
    xcb_configure_window(connection, event.window, event.value_mask, values[popCount .. $].ptr);

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
