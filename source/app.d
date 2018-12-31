import std.exception : enforce;
import std.experimental.logger;
import xcb.xcb;

class Redbat
{
    xcb_connection_t* connection;
    xcb_screen_t* screen;
    xcb_window_t rootWindow;
    xcb_window_t[xcb_window_t] frameOf;
    xcb_gcontext_t titlebarGC;

    this()
    {
        int screenNum;
        connection = xcb_connect(":1", &screenNum); // Test on :1
        enforce(xcb_connection_has_error(connection) == 0, "Failed to connect");

        screen = screenOfDisplay(connection, screenNum);
        enforce(screen !is null, "Screen is null");

        rootWindow = screen.root;

        titlebarGC = xcb_generate_id(connection);
        immutable fgColor = "DeepPink";
        auto reply = xcb_alloc_named_color_reply(connection, xcb_alloc_named_color(connection, screen.default_colormap,
                cast(ushort) fgColor.length, fgColor.ptr), null);
        immutable fgPixel = reply is null ? screen.black_pixel : reply.pixel;
        uint[] valuesGC = [fgPixel, 0];
        import core.stdc.stdlib : free;

        free(reply);
        xcb_create_gc(connection, titlebarGC, rootWindow, XCB_GC_FOREGROUND | XCB_GC_GRAPHICS_EXPOSURES, valuesGC.ptr);
    }

    ~this()
    {
        xcb_free_gc(connection, titlebarGC); // XXX: required?
        xcb_disconnect(connection);
    }

    void run()
    {
        immutable uint mask = XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT;
        auto cookie = xcb_change_window_attributes_checked(connection, rootWindow, XCB_CW_EVENT_MASK, &mask);
        enforce(xcb_request_check(connection, cookie) is null, "Another wm is running");

        xcb_flush(connection);

        infof("Successfully obtained root window of %#x", rootWindow);

        manageChildrenOfRoot();

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
            case XCB_EXPOSE:
                infof("XCB_EXPOSE %s", eventType);
                onExpose(cast(xcb_expose_event_t*) event);
                xcb_flush(connection);
                break;
            case XCB_BUTTON_PRESS:
                infof("XCB_BUTTON_PRESS %s", eventType);
                onButtonPress(cast(xcb_button_press_event_t*) event);
                break;
            case XCB_BUTTON_RELEASE:
                infof("XCB_BUTTON_RELEASE %s", eventType);
                onButtonRelease(cast(xcb_button_release_event_t*) event);
                break;
            case XCB_MOTION_NOTIFY:
                infof("XCB_MOTION_NOTIFY %s", eventType);
                onMotionNotify(cast(xcb_motion_notify_event_t*) event);
                break;
            case XCB_UNMAP_NOTIFY:
                infof("XCB_UNMAP_NOTIFY %s", eventType);
                onUnmapNotify(cast(xcb_unmap_notify_event_t*) event);
                break;
            case XCB_MAP_REQUEST:
                infof("XCB_MAP_REQUEST %s", eventType);
                onMapRequest(cast(xcb_map_request_event_t*) event);
                break;
            case XCB_CONFIGURE_REQUEST:
                infof("XCB_CONFIGURE_REQUEST %s", eventType);
                onConfigureRequest(cast(xcb_configure_request_event_t*) event);
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

    struct Geometry
    {
        short x;
        short y;
        ushort width;
        ushort height;
        ushort border_width;
    }

    auto getGeometry(xcb_drawable_t window)
    {
        Geometry geo;
        auto geo_p = xcb_get_geometry_reply(connection, xcb_get_geometry(connection, window), null);
        if (geo_p !is null)
        {
            geo.x = geo_p.x;
            geo.y = geo_p.y;
            geo.width = geo_p.width;
            geo.height = geo_p.height;
            geo.border_width = geo_p.border_width;
            import core.stdc.stdlib : free;

            free(geo_p);
        }
        return geo;
    }

    void manageChildrenOfRoot()
    {
        auto reply = xcb_query_tree_reply(connection, xcb_query_tree(connection, rootWindow), null);
        if (reply is null)
        {
            error("Cannot get children of root");
            return;
        }
        const children = xcb_query_tree_children(reply);

        import core.stdc.stdlib : free;

        foreach (i, child; children[0 .. xcb_query_tree_children_length(reply)])
        {
            auto attr = xcb_get_window_attributes_reply(connection, xcb_get_window_attributes(connection, child), null);
            if (attr is null)
            {
                errorf("Cannot get attributes of %#x", child);
                continue;
            }
            scope (exit)
            {
                free(attr);
            }
            if (attr.map_state != XCB_MAP_STATE_VIEWABLE || attr.override_redirect)
            {
                continue;
            }

            infof("%#x", child);
            frameOf[child] = applyFrame(child);
        }

        free(reply);
    }

    void onExpose(xcb_expose_event_t* event)
    {
        // XXX: assume event.window to be titlebar
        immutable geo = getGeometry(event.window);
        immutable margin = ushort(3);
        auto rect = xcb_rectangle_t(margin, margin, cast(ushort)(geo.width - margin * 2), cast(ushort)(geo.height - margin * 2));
        xcb_poly_fill_rectangle(connection, event.window, titlebarGC, 1, &rect);
    }

    void onButtonPress(xcb_button_press_event_t* event)
    {
        // XXX: assume event.event to be frame
        info(*event);
        foreach (kv; frameOf.byKeyValue)
        {
            if (event.event == kv.value)
            {
                infof("Set focus: %#x", kv.key);
                xcb_set_input_focus(connection, XCB_INPUT_FOCUS_POINTER_ROOT, kv.key, XCB_CURRENT_TIME);
                immutable uint v = XCB_STACK_MODE_ABOVE;
                xcb_configure_window(connection, event.event, XCB_CONFIG_WINDOW_STACK_MODE, &v);
                xcb_flush(connection);
                break;
            }
        }
    }

    void onButtonRelease(xcb_button_release_event_t* event)
    {
        info(*event);
    }

    void onMotionNotify(xcb_motion_notify_event_t* event)
    {
        info(*event);
    }

    void onUnmapNotify(xcb_unmap_notify_event_t* event)
    {
        auto frame_p = event.window in frameOf;
        if (frame_p is null)
        {
            infof("unmap %#x, unmanaged", event.window);
            return;
        }

        immutable frame = *frame_p;
        infof("unmap %#x, frame %#x", event.window, frame);

        immutable frameGeo = getGeometry(frame);
        infof("Frame to be removed is at (%s, %s)", frameGeo.x, frameGeo.y);

        xcb_reparent_window(connection, event.window, rootWindow, frameGeo.x, frameGeo.y);
        xcb_change_save_set(connection, XCB_SET_MODE_DELETE, event.window);
        xcb_destroy_window(connection, frame);
        infof("destroy frame %#x", frame);
        xcb_flush(connection);

        frameOf.remove(event.window);
    }

    xcb_window_t createTitlebar(xcb_window_t frame, ushort width, ushort height)
    {
        auto titlebar = xcb_generate_id(connection);
        uint[] values = [screen.white_pixel, XCB_EVENT_MASK_BUTTON_RELEASE | XCB_EVENT_MASK_BUTTON_1_MOTION | XCB_EVENT_MASK_EXPOSURE];
        xcb_create_window(connection, XCB_COPY_FROM_PARENT, titlebar, frame, 0, 0, width, height, 0,
                XCB_WINDOW_CLASS_INPUT_OUTPUT, screen.root_visual, XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK, values.ptr);
        xcb_flush(connection);
        return titlebar;
    }

    xcb_window_t createFrame(short x, short y, ushort width, ushort height)
    {
        auto frame = xcb_generate_id(connection);
        immutable uint mask = XCB_EVENT_MASK_BUTTON_PRESS | XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY | XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT;
        xcb_create_window(connection, XCB_COPY_FROM_PARENT, frame, rootWindow, x, y, width, height, 3,
                XCB_WINDOW_CLASS_INPUT_OUTPUT, screen.root_visual, XCB_CW_EVENT_MASK, &mask);
        xcb_flush(connection);
        return frame;
    }

    xcb_window_t applyFrame(xcb_window_t window)
    {
        immutable tbHeight = 30;
        immutable geo = getGeometry(window);
        auto frame = createFrame(geo.x, geo.y, cast(ushort)(geo.width + geo.border_width * 2),
                cast(ushort)(tbHeight + geo.height + geo.border_width * 2));
        auto titlebar = createTitlebar(frame, geo.width, tbHeight);
        import std.conv : to;

        immutable frameName = "Frame of " ~ window.to!string(16);
        immutable titlebarName = "Titlebar of " ~ window.to!string(16);
        xcb_change_property(connection, XCB_PROP_MODE_APPEND, frame, XCB_ATOM_WM_NAME, XCB_ATOM_STRING, 8,
                cast(uint) frameName.length, frameName.ptr);
        xcb_change_property(connection, XCB_PROP_MODE_APPEND, titlebar, XCB_ATOM_WM_NAME, XCB_ATOM_STRING, 8,
                cast(uint) titlebarName.length, titlebarName.ptr);

        xcb_change_save_set(connection, XCB_SET_MODE_INSERT, window);
        xcb_reparent_window(connection, window, frame, 0, tbHeight);
        xcb_map_window(connection, frame);
        xcb_map_window(connection, titlebar);
        xcb_map_window(connection, window);
        xcb_flush(connection);

        return frame;
    }

    void onMapRequest(xcb_map_request_event_t* event)
    {
        frameOf[event.window] = applyFrame(event.window);
    }

    void onConfigureRequest(xcb_configure_request_event_t* event)
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
        if (event.parent != rootWindow)
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
        // TODO: redraw titlebar
        xcb_flush(connection);
    }
}

void main()
{
    auto redbat = new Redbat;
    redbat.run();
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
