import core.stdc.stdlib : free;
import redbat.cursor;
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
    immutable ushort titlebarMinWidth = 120;

    CursorManager cursorManager;

    enum DragMode
    {
        none,
        titlebar,
        border
    }

    enum BorderDragDirection
    {
        none,

        top,
        bottom,
        left,
        right,

        topLeft,
        topRight,
        bottomLeft,
        bottomRight
    }

    struct DragManager
    {
        Frame frame;
        bool inDrag;
        short initRootX, initRootY;
        short currentRootX, currentRootY;
        Geometry initGeo;
        DragMode mode;
        BorderDragDirection dir;
    }

    DragManager dragManager;

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
                cf.getPixByColorName("LightSkyBlue"), cf.getPixByColorName("DodgerBlue"), titlebarHeight, titlebarMinWidth);
        cursorManager = new CursorManager(root);
    }

    ~this()
    {
        xcb_free_gc(connection, titlebarAppearance.unfocusedGC);
        xcb_free_gc(connection, titlebarAppearance.focusedGC);

        xcb_disconnect(connection);
    }

    void run()
    {
        immutable uint mask = XCB_EVENT_MASK_BUTTON_RELEASE | XCB_EVENT_MASK_POINTER_MOTION
            | XCB_EVENT_MASK_BUTTON_1_MOTION | XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT;
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

    bool isRootXYWithinTitlebar(Frame frame, short rootX, short rootY)
    {
        auto reply = xcb_translate_coordinates_reply(connection, xcb_translate_coordinates(connection, root.window,
                frame.titlebar.window, rootX, rootY), null);
        if (reply is null)
        {
            warning("Failed to translate coords");
            return false;
        }

        immutable titlebarGeo = frame.titlebar.geometry;
        immutable ret = 0 <= reply.dst_x && reply.dst_x < titlebarGeo.width && 0 <= reply.dst_y && reply.dst_y < titlebarGeo.height;
        infof("(x, y) = (%s, %s), %s", reply.dst_x, reply.dst_y, ret);
        free(reply);

        return ret;
    }

    alias WithinBorderDetail = BorderDragDirection;
    enum ushort aroundCorner = 8;

    WithinBorderDetail isRootXYWithinBorder(Frame frame, short rootX, short rootY)
    {
        auto reply = xcb_translate_coordinates_reply(connection, xcb_translate_coordinates(connection, root.window,
                frame.window, rootX, rootY), null);
        if (reply is null)
        {
            warning("Failed to translate coords");
            return WithinBorderDetail.none;
        }
        scope (exit)
        {
            free(reply);
        }

        immutable frameGeo = frame.geometry;
        if (0 <= reply.dst_x + frameGeo.borderWidth && reply.dst_x < frameGeo.width + frameGeo.borderWidth
                && 0 <= reply.dst_y + frameGeo.borderWidth && reply.dst_y < frameGeo.height + frameGeo.borderWidth)
        {
            if (reply.dst_x < 0) // left border
            {
                if (reply.dst_y + frameGeo.borderWidth < aroundCorner)
                {
                    return BorderDragDirection.topLeft;
                }
                else if (reply.dst_y + aroundCorner >= frameGeo.height + frameGeo.borderWidth)
                {
                    return BorderDragDirection.bottomLeft;
                }
                else
                {
                    return BorderDragDirection.left;
                }
            }
            else if (frameGeo.width <= reply.dst_x) // right border
            {
                if (reply.dst_y + frameGeo.borderWidth < aroundCorner)
                {
                    return BorderDragDirection.topRight;
                }
                else if (reply.dst_y + aroundCorner >= frameGeo.height + frameGeo.borderWidth)
                {
                    return BorderDragDirection.bottomRight;
                }
                else
                {
                    return BorderDragDirection.right;
                }
            }
            else if (reply.dst_y < 0) // top border
            {
                if (reply.dst_x + frameGeo.borderWidth < aroundCorner)
                {
                    return BorderDragDirection.topLeft;
                }
                else if (reply.dst_x + aroundCorner >= frameGeo.width + frameGeo.borderWidth)
                {
                    return BorderDragDirection.topRight;
                }
                else
                {
                    return BorderDragDirection.top;
                }
            }
            else if (frameGeo.height <= reply.dst_y) // bottom border
            {
                if (reply.dst_x + frameGeo.borderWidth < aroundCorner)
                {
                    return BorderDragDirection.bottomLeft;
                }
                else if (reply.dst_x + aroundCorner >= frameGeo.width + frameGeo.borderWidth)
                {
                    return BorderDragDirection.bottomRight;
                }
                else
                {
                    return BorderDragDirection.bottom;
                }
            }
        }

        return WithinBorderDetail.none;
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

                if (isRootXYWithinTitlebar(frame, event.root_x, event.root_y))
                {
                    if (event.detail == XCB_BUTTON_INDEX_1)
                    {
                        dragManager = DragManager(frame, true, event.root_x, event.root_y, event.root_x, event.root_y,
                                frame.geometry, DragMode.titlebar);
                        cursorManager.setStyle(CursorStyle.moving);
                        xcb_grab_pointer(connection, 0, root.window,
                                XCB_EVENT_MASK_BUTTON_PRESS | XCB_EVENT_MASK_BUTTON_RELEASE | XCB_EVENT_MASK_BUTTON_1_MOTION,
                                XCB_GRAB_MODE_ASYNC, XCB_GRAB_MODE_ASYNC, XCB_NONE, cursorManager.rawCursor, event.time);
                    }
                    else if (event.detail == XCB_BUTTON_INDEX_2)
                    {
                        closeWindow(frame, event.time);
                        return;
                    }
                }
                else if (immutable d = isRootXYWithinBorder(frame, event.root_x, event.root_y))
                {
                    if (event.detail == XCB_BUTTON_INDEX_1)
                    {
                        dragManager = DragManager(frame, true, event.root_x, event.root_y, event.root_x, event.root_y,
                                frame.geometry, DragMode.border, d);
                        xcb_grab_pointer(connection, 0, root.window,
                                XCB_EVENT_MASK_BUTTON_PRESS | XCB_EVENT_MASK_BUTTON_RELEASE | XCB_EVENT_MASK_BUTTON_1_MOTION,
                                XCB_GRAB_MODE_ASYNC, XCB_GRAB_MODE_ASYNC, XCB_NONE, cursorManager.rawCursor, event.time);
                    }
                }
                else
                {
                    cursorManager.setStyle(CursorStyle.normal);
                }

                if (!frame.focused)
                {
                    focusWindow(frame, event.time);
                }
            }
            else
            {
                warningf("Button presse event is detected above unmanaged window %#x", event.child);
            }
        }
    }

    void setCursor(Frame frame, short rootX, short rootY)
    {
        if (isRootXYWithinTitlebar(frame, rootX, rootY))
        {
            infof("On titlebar of frame %#x", frame.window);
            cursorManager.setStyle(CursorStyle.normal);
            return;
        }

        immutable d = isRootXYWithinBorder(frame, rootX, rootY);
        with (WithinBorderDetail)
        {
            final switch (d)
            {
            case none:
                cursorManager.setStyle(CursorStyle.normal);
                return;
            case top:
                cursorManager.setStyle(CursorStyle.top);
                break;
            case bottom:
                cursorManager.setStyle(CursorStyle.bottom);
                break;
            case left:
                cursorManager.setStyle(CursorStyle.left);
                break;
            case right:
                cursorManager.setStyle(CursorStyle.right);
                break;
            case topLeft:
                cursorManager.setStyle(CursorStyle.topLeft);
                break;
            case topRight:
                cursorManager.setStyle(CursorStyle.topRight);
                break;
            case bottomLeft:
                cursorManager.setStyle(CursorStyle.bottomLeft);
                break;
            case bottomRight:
                cursorManager.setStyle(CursorStyle.bottomRight);
                break;
            }
        }
    }

    void onButtonRelease(xcb_button_release_event_t* event)
    {
        // XXX: assume event.event to be root
        if (dragManager.inDrag && event.detail == XCB_BUTTON_INDEX_1)
        {
            xcb_ungrab_pointer(connection, event.time);
            dragManager = DragManager();
            import std.algorithm.searching : find;

            auto r = frames[].find!"a.window==b"(event.child);
            if (!r.empty)
            {
                setCursor(r.front, event.root_x, event.root_y);
            }
        }
    }

    bool doDragging()
    {
        if (!dragManager.inDrag || dragManager.mode == DragMode.none)
        {
            return false;
        }

        auto newGeo = dragManager.frame.geometry;
        const initGeo = dragManager.initGeo;
        infof("Pointer: start(%s, %s) => current(%s, %s)", dragManager.initRootX, dragManager.initRootY,
                dragManager.currentRootX, dragManager.currentRootY);
        immutable dx = dragManager.currentRootX - dragManager.initRootX;
        immutable dy = dragManager.currentRootY - dragManager.initRootY;

        void moveByDeltaXFromInit(int dy)
        {
            newGeo.x = cast(short)(initGeo.x + dx);
        }

        void moveByDeltaYFromInit(int dy)
        {
            newGeo.y = cast(short)(initGeo.y + dy);
        }

        enum CorrectionDetail
        {
            none = 0,
            width = 1 << 0,
            height = 1 << 1
        }

        auto resizeByDeltaFromInit(int dw, int dh)
        {
            import std.algorithm.comparison : max;

            newGeo.width = cast(ushort) max(0, initGeo.width + dw);
            newGeo.height = cast(ushort) max(0, initGeo.height + dh);
            auto correctedNewGeo = dragManager.frame.correctNewGeometry(newGeo);
            int correctionDetail;
            if (correctedNewGeo.width != newGeo.width)
            {
                correctionDetail |= CorrectionDetail.width;
            }
            if (correctedNewGeo.height != newGeo.height)
            {
                correctionDetail |= CorrectionDetail.height;
            }

            if (correctionDetail)
            {
                newGeo = correctedNewGeo;
            }

            return correctionDetail;
        }

        final switch (dragManager.mode)
        {
        case DragMode.none:
            warning("Somehow in drag mode!");
            return false;
        case DragMode.titlebar:
            infof("Dragging titlebar %#x", dragManager.frame.titlebar.window);
            moveByDeltaXFromInit(dx);
            moveByDeltaYFromInit(dy);
            dragManager.frame.geometry = newGeo;
            return true;
        case DragMode.border:
            break;
        }
        final switch (dragManager.dir)
        {
        case BorderDragDirection.none:
            return false;
        case BorderDragDirection.top:
            if (!(resizeByDeltaFromInit(0, -dy) & CorrectionDetail.height))
            {
                moveByDeltaYFromInit(dy);
            }
            break;
        case BorderDragDirection.bottom:
            resizeByDeltaFromInit(0, dy);
            break;
        case BorderDragDirection.left:
            if (!(resizeByDeltaFromInit(-dx, 0) & CorrectionDetail.width))
            {
                moveByDeltaXFromInit(dx);
            }
            break;
        case BorderDragDirection.right:
            resizeByDeltaFromInit(dx, 0);
            break;
        case BorderDragDirection.topLeft:
            immutable detail = resizeByDeltaFromInit(-dx, -dy);
            if (!(detail & CorrectionDetail.height))
            {
                moveByDeltaYFromInit(dy);
            }
            if (!(detail & CorrectionDetail.width))
            {
                moveByDeltaXFromInit(dx);
            }
            break;
        case BorderDragDirection.topRight:
            if (!(resizeByDeltaFromInit(dx, -dy) & CorrectionDetail.height))
            {
                moveByDeltaYFromInit(dy);
            }
            break;
        case BorderDragDirection.bottomLeft:
            if (!(resizeByDeltaFromInit(-dx, dy) & CorrectionDetail.width))
            {
                moveByDeltaXFromInit(dx);
            }
            break;
        case BorderDragDirection.bottomRight:
            resizeByDeltaFromInit(dx, dy);
            break;
        }
        dragManager.frame.geometry = newGeo;

        return true;
    }

    void onMotionNotify(xcb_motion_notify_event_t* event)
    {
        // XXX: assume event.event to be root
        //infof("%#x %#x", event.event, event.child);

        if (dragManager.inDrag)
        {
            import std.algorithm.searching : canFind;

            if (frames[].canFind(dragManager.frame) && event.state & XCB_EVENT_MASK_BUTTON_1_MOTION)
            {
                dragManager.currentRootX = event.root_x;
                dragManager.currentRootY = event.root_y;
                dragManager.inDrag = doDragging();
                return;
            }
            warning("Somehow in drag mode!");
        }

        // Not dragging
        dragManager = DragManager();
        import std.algorithm.searching : find;

        auto r = frames[].find!"a.window==b"(event.child);
        if (r.empty)
        {
            cursorManager.setStyle(CursorStyle.normal);
            return;
        }

        setCursor(r.front, event.root_x, event.root_y);
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

        import redbat.atom;

        immutable wmState = [1, XCB_NONE];
        xcb_change_property(connection, XCB_PROP_MODE_REPLACE, client, getAtomByName(connection, "WM_STATE"),
                getAtomByName(connection, "WM_STATE"), 32, cast(uint) wmState.length, wmState.ptr);
        immutable frameExtents = [frameBorderWidth, frameBorderWidth, titlebarAppearance.height + frameBorderWidth, frameBorderWidth];
        xcb_change_property(connection, XCB_PROP_MODE_REPLACE, client, getAtomByName(connection, "_NET_FRAME_EXTENTS"),
                XCB_ATOM_CARDINAL, 32, cast(uint) frameExtents.length, frameExtents.ptr);

        frames.insert(frame);
        return frame.window;
    }

    void onMapRequest(xcb_map_request_event_t* event)
    {
        auto reply = xcb_get_window_attributes_reply(connection, xcb_get_window_attributes(connection, event.window), null);
        if (reply is null)
        {
            return;
        }

        if (!reply.override_redirect)
        {
            applyFrame(event.window, false);
        }
        free(reply);
    }

    void onConfigureRequest(xcb_configure_request_event_t* event)
    {
        infof("pw = (%#x, %#x), xy = (%s, %s), wh = (%s, %s)", event.parent, event.window, event.x, event.y, event.width, event.height); // Needed to handle manually
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
                geoFrame.width = event.width;
                geoFrame.width += event.border_width * 2;
            }
            if (event.value_mask & XCB_CONFIG_WINDOW_HEIGHT)
            {
                geoFrame.height = event.height;
                geoFrame.height += frame.titlebar.geometry.height;
                geoFrame.height += event.border_width * 2;
            }

            // Set values in this order!!
            if (event.value_mask & XCB_CONFIG_WINDOW_BORDER_WIDTH)
            {
                miscValueMask |= XCB_CONFIG_WINDOW_BORDER_WIDTH;
                miscValues ~= event.border_width;
            }
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

            if (miscValueMask)
            {
                xcb_configure_window(connection, event.window, miscValueMask, miscValues.ptr);
            }

            frame.geometry = geoFrame;
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
