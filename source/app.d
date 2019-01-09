import core.stdc.stdlib : free;
import redbat.geometry;
import redbat.window;
import std.exception : enforce;
import std.experimental.logger;
import xcb.xcb;

class Redbat
{
    xcb_connection_t* connection;
    xcb_screen_t* screen;
    Window root;
    import std.container.rbtree;

    RedBlackTree!(Frame, "a.window<b.window") frames;
    TitlebarAppearance titlebarAppearance;
    immutable ushort frameBorderWidth = 3;
    immutable ushort titlebarHeight = 30;

    this()
    {
        int screenNum;
        connection = xcb_connect(":1", &screenNum); // Test on :1
        enforce(xcb_connection_has_error(connection) == 0, "Failed to connect");

        screen = screenOfDisplay(connection, screenNum);
        enforce(screen !is null, "Screen is null");

        root = new Window(connection, screen, screen.root);
        frames = new typeof(frames);
        import redbat.cosmetic;

        auto cf = new CosmeticFactory(root);
        titlebarAppearance = TitlebarAppearance(cf.createGCWithFG("LightPink"), cf.createGCWithFG("DeepPink"),
                cf.getPixByColorName("LightSkyBlue"), cf.getPixByColorName("DodgerBlue"), titlebarHeight);
    }

    ~this()
    {
        xcb_free_gc(connection, titlebarAppearance.unfocusedGC);
        xcb_free_gc(connection, titlebarAppearance.focusedGC);

        xcb_disconnect(connection);
    }

    void run()
    {
        immutable uint mask = XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT;
        auto cookie = xcb_change_window_attributes_checked(connection, root.window, XCB_CW_EVENT_MASK, &mask);
        enforce(xcb_request_check(connection, cookie) is null, "Another wm is running");

        infof("Successfully obtained root window of %#x", root.window);

        manageChildrenOfRoot();

        xcb_grab_button(connection, 0, root.window, XCB_EVENT_MASK_BUTTON_PRESS | XCB_EVENT_MASK_BUTTON_RELEASE,
                XCB_GRAB_MODE_SYNC, XCB_GRAB_MODE_ASYNC, XCB_NONE, XCB_NONE, XCB_BUTTON_INDEX_ANY, XCB_MOD_MASK_ANY);

        xcb_flush(connection);

        while (true)
        {
            xcb_allow_events(connection, XCB_ALLOW_REPLAY_POINTER, XCB_CURRENT_TIME);
            auto event = xcb_poll_for_event(connection);
            if (event is null)
            {
                if (xcb_connection_has_error(connection))
                {
                    break;
                }
                import core.thread;

                Thread.sleep(20.dur!"msecs"); // Save the earth!!
                continue;
            }

            immutable eventType = event.response_type & ~0x80;
            switch (eventType)
            {
            case XCB_EXPOSE:
                infof("XCB_EXPOSE %s", eventType);
                onExpose(cast(xcb_expose_event_t*) event);
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
            case XCB_FOCUS_IN:
                infof("XCB_FOCUS_IN %s", eventType);
                onFocusIn(cast(xcb_focus_in_event_t*) event);
                break;
            case XCB_FOCUS_OUT:
                infof("XCB_FOCUS_OUT %s", eventType);
                onFocusOut(cast(xcb_focus_out_event_t*) event);
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
            case XCB_PROPERTY_NOTIFY:
                infof("XCB_PROPERTY_NOTIFY %s", eventType);
                onPropertyNotify(cast(xcb_property_notify_event_t*) event);
                break;
            default:
                warningf("Unknown event: %s", eventType);
                break;
            }
            xcb_flush(connection);

            free(event);
        }
    }

    void manageChildrenOfRoot()
    {
        auto reply = xcb_query_tree_reply(connection, xcb_query_tree(connection, root.window), null);
        if (reply is null)
        {
            error("Cannot get children of root");
            return;
        }

        const children = xcb_query_tree_children(reply);
        immutable len = xcb_query_tree_children_length(reply);
        foreach (i, child; children[0 .. len])
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

            infof("Manage %#x", child);
            applyFrame(child, true);
        }

        free(reply);
    }

    void onExpose(xcb_expose_event_t* event)
    {
        // XXX: assume event.window to be titlebar
        import std.algorithm.searching : find;

        auto r = frames[].find!"a.titlebar.window==b"(event.window);
        if (!r.empty)
        {
            r.front.draw();
        }
    }

    void closeWindow(Frame frame, xcb_timestamp_t time = XCB_CURRENT_TIME)
    {
        import std.algorithm.searching : find;

        auto r = frames[].find(frame);
        if (!r.empty)
        {
            r.front.close(time);
        }
        else
        {
            errorf("An unmanaged frame: %#x", frame.window);
        }
    }

    void focusWindow(Frame frame, xcb_timestamp_t time = XCB_CURRENT_TIME)
    {
        import std.algorithm.searching : find;

        auto r = frames[].find(frame);
        if (!r.empty)
        {
            infof("Set focus: %#x", frame.window);
            r.front.focus(time);
        }
        else
        {
            errorf("An unmanaged frame: %#x", frame.window);
        }
    }

    void onButtonPress(xcb_button_press_event_t* event)
    {
        // XXX: assume event.event to be root
        infof("%#x %#x", event.event, event.child);
        if (event.event == root.window)
        {
            import std.algorithm.searching : find;

            auto r = frames[].find!"a.window==b"(event.child);
            if (!r.empty)
            {
                auto frame = r.front;
                if (event.detail == XCB_BUTTON_INDEX_2)
                {
                    auto reply = xcb_translate_coordinates_reply(connection, xcb_translate_coordinates(connection,
                            root.window, frame.titlebar.window, event.root_x, event.root_y), null);
                    if (reply is null)
                    {
                        warning("Failed to translate coords");
                        return;
                    }

                    immutable titlebarGeo = frame.titlebar.geometry;
                    if ( /*0 <= reply.dst_x && */ reply.dst_x < titlebarGeo.width && /*0 <= reply.dst_y &&*/ reply.dst_y
                            < titlebarGeo.height) // event is in titlebar region
                            {
                        closeWindow(frame, event.time);
                    }
                    else
                    {
                        focusWindow(frame, event.time);
                    }
                    import core.stdc.stdlib : free;

                    free(reply);
                }
                else
                {
                    focusWindow(frame, event.time);
                }
            }
            else
            {
                infof("Button presse event is detected above unmanaged window %#x", event.child);
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

    void onFocusIn(xcb_focus_in_event_t* event)
    {
        // XXX: assume event.event to be frame
        infof("Focused %#x", event.event);
        import std.algorithm.searching : find;

        auto r = frames[].find!"a.window==b"(event.event);

        if (r.empty)
        {
            warningf("Unmanaged frame %#x", event.event);
            return;
        }
        r.front.onFocused();
    }

    void onFocusOut(xcb_focus_out_event_t* event)
    {
        // XXX: assume event.event to be frame
        infof("Unfocused %#x", event.event);
        import std.algorithm.searching : find;

        auto r = frames[].find!"a.window==b"(event.event);

        if (r.empty)
        {
            warningf("Unmanaged frame %#x", event.event);
            return;
        }
        r.front.onUnforcused();
    }

    void onUnmapNotify(xcb_unmap_notify_event_t* event)
    {
        // XXX: assume event.window to be client
        import std.algorithm.searching : find;

        auto r = frames[].find!"a.client.window==b"(event.window);
        if (r.empty)
        {
            infof("unmap %#x, unmanaged", event.window);
            return;
        }

        auto frame = r.front;
        infof("unmap %#x, frame %#x", event.window, frame.window);

        frame.unreparentClient();
        frame.destroy_();
        infof("destroy frame %#x", frame.window);

        frames.removeKey(frame);
    }

    xcb_window_t applyFrame(xcb_window_t client, bool forExisting)
    {
        immutable geo = getGeometry(connection, client);
        short frameX = geo.x;
        short frameY = geo.y;
        if (forExisting)
        {
            frameX -= frameBorderWidth;
            frameY -= frameBorderWidth;
            frameY -= titlebarHeight;
        }

        immutable uint mask = XCB_EVENT_MASK_PROPERTY_CHANGE;
        xcb_change_window_attributes(connection, client, XCB_CW_EVENT_MASK, &mask);

        auto frame = new Frame(root, Geometry(frameX, frameY, cast(ushort)(geo.width + geo.borderWidth * 2),
                cast(ushort)(titlebarHeight + geo.height + geo.borderWidth * 2), frameBorderWidth), titlebarAppearance);
        frame.createTitlebar();
        frame.reparentClient(client);
        frame.mapAll();

        frames.insert(frame);
        return frame.window;
    }

    void onMapRequest(xcb_map_request_event_t* event)
    {
        applyFrame(event.window, false);
    }

    void onConfigureRequest(xcb_configure_request_event_t* event)
    {
        infof("pw = (%#x, %#x), xy = (%s, %s), wh = (%s, %s)", event.parent, event.window, event.x, event.y, event.width, event.height);

        // Needed to handle manually
        if (event.parent == root.window)
        {
            infof("ConfigReq from unmanaged client: %#x", event.window);
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
        }
        else
        {
            import std.algorithm.searching : find;

            auto r = frames[].find!"a.window==b"(event.parent);

            if (r.empty)
            {
                warningf("Configure request from unknown client %#x", event.window);
                return;
            }
            auto frame = r.front;
            auto geoClient = frame.client.geometry;
            auto geoTitlebar = frame.titlebar.geometry;
            auto geoFrame = frame.geometry;
            ushort miscValueMask;
            uint[] miscValues;

            if (event.value_mask & XCB_CONFIG_WINDOW_X)
            {
                geoFrame.x = event.x;
            }
            if (event.value_mask & XCB_CONFIG_WINDOW_Y)
            {
                geoFrame.y = event.y;
            }
            if (event.value_mask & XCB_CONFIG_WINDOW_WIDTH)
            {
                geoClient.width = event.width;
                geoTitlebar.width = event.width;
                geoTitlebar.width += event.border_width * 2;
                geoFrame.width = event.width;
                geoFrame.width += event.border_width * 2;
            }
            if (event.value_mask & XCB_CONFIG_WINDOW_HEIGHT)
            {
                geoClient.height = event.height;
                geoFrame.height = event.height;
                geoFrame.height += geoTitlebar.height;
                geoFrame.height += event.border_width * 2;
            }
            if (event.value_mask & XCB_CONFIG_WINDOW_BORDER_WIDTH)
            {
                geoClient.borderWidth = event.border_width;
            }

            // Set values in this order!!
            if (event.value_mask & XCB_CONFIG_WINDOW_SIBLING)
            {
                miscValueMask |= XCB_CONFIG_WINDOW_SIBLING;
                miscValues ~= event.sibling;
            }
            if (event.value_mask & XCB_CONFIG_WINDOW_STACK_MODE)
            {
                miscValueMask |= XCB_CONFIG_WINDOW_STACK_MODE;
                miscValues ~= event.stack_mode;
            }

            frame.client.geometry = geoClient;
            if (miscValueMask)
            {
                xcb_configure_window(connection, event.window, miscValueMask, miscValues.ptr);
            }

            frame.geometry = geoFrame;
            frame.titlebar.geometry = geoTitlebar;
        }
    }

    void onPropertyNotify(xcb_property_notify_event_t* event)
    {
        import redbat.atom;

        infof("%#x, %s", event.window, getAtomName(connection, event.atom));
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
