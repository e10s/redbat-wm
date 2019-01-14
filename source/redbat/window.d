module redbat.window;

import redbat.atom;
import redbat.geometry;
import std.experimental.logger;
import xcb.icccm;
import xcb.xcb;

class Window
{
    xcb_connection_t* connection;
    xcb_screen_t* screen;
    xcb_window_t window;
    this(xcb_connection_t* connection, xcb_screen_t* screen, xcb_window_t window)
    {
        this.connection = connection;
        this.screen = screen;
        this.window = window;
    }

    this(Window parent, xcb_window_t window)
    {
        this.connection = parent.connection;
        this.screen = parent.screen;
        this.window = window;
    }

    void map()
    {
        xcb_map_window(connection, window);
    }

    void destroy_()
    {
        xcb_destroy_window(connection, window);
    }

    void kill()
    {
        xcb_kill_client(connection, window);
    }

    @property Geometry geometry()
    {
        return getGeometry(connection, window);
    }

    @property Geometry geometry(Geometry newGeo)
    {
        ushort valueMask = XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_Y | XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT
            | XCB_CONFIG_WINDOW_BORDER_WIDTH;
        uint[] values = [newGeo.x, newGeo.y, newGeo.width, newGeo.height, newGeo.borderWidth];

        xcb_configure_window(connection, window, valueMask, values.ptr);
        return newGeo;
    }
}

class Frame : Window
{
    Titlebar titlebar; // child
    Window client; // child
    bool focused;
    TitlebarAppearance titlebarAppearance;
    this(Window root, Geometry geo, TitlebarAppearance titlebarAppearance)
    {
        auto frame = xcb_generate_id(root.connection);
        super(root, frame);
        immutable uint mask = XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY | XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT | XCB_EVENT_MASK_FOCUS_CHANGE;
        xcb_create_window(connection, XCB_COPY_FROM_PARENT, frame, root.window, geo.x, geo.y, geo.width, geo.height,
                geo.borderWidth, XCB_WINDOW_CLASS_INPUT_OUTPUT, screen.root_visual, XCB_CW_EVENT_MASK, &mask);

        this.titlebarAppearance = titlebarAppearance;
    }

    override @property Geometry geometry()
    {
        return super.geometry;
    }

    override @property Geometry geometry(Geometry newGeo)
    {
        immutable oldGeo = geometry;
        immutable clientGeo = client.geometry;
        immutable minClientAreaWidth = cast(ushort)(1 + clientGeo.borderWidth * 2);
        immutable minClientAreaHeight = cast(ushort)(1 + clientGeo.borderWidth * 2);

        import std.algorithm.comparison : max;

        newGeo.width = max(minClientAreaWidth, titlebarAppearance.minWidth, newGeo.width);
        newGeo.height = max(cast(ushort)(minClientAreaHeight + titlebarAppearance.height), newGeo.height);
        immutable dw = cast(int) newGeo.width - oldGeo.width;
        immutable dh = cast(int) newGeo.height - oldGeo.height;

        if (dw || dh)
        {
            immutable uint[] clientValues = [clientGeo.width + dw, clientGeo.height + dh];
            xcb_configure_window(connection, client.window, XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT, clientValues.ptr);
        }
        if (dw)
        {
            immutable uint titlebarValue = titlebar.geometry.width + dw;
            xcb_configure_window(connection, titlebar.window, XCB_CONFIG_WINDOW_WIDTH, &titlebarValue);
        }
        super.geometry(newGeo);
        return newGeo;
    }

    Titlebar createTitlebar()
    {
        if (titlebar is null)
        {
            titlebar = new Titlebar(this, Geometry(0, 0, geometry.width, titlebarAppearance.height, 0));
        }
        return titlebar;
    }

    void reparentClient(xcb_window_t client)
    {
        this.client = new Window(this, client);
        xcb_change_save_set(connection, XCB_SET_MODE_INSERT, client);
        xcb_reparent_window(connection, client, window, 0, titlebar.geometry.height);
        import std.conv : to;

        immutable frameName = "Frame of " ~ client.to!string(16);
        xcb_change_property(connection, XCB_PROP_MODE_APPEND, window, XCB_ATOM_WM_NAME, XCB_ATOM_STRING, 8,
                cast(uint) frameName.length, frameName.ptr);
        // TODO: If client is already focused, onFocused has to be called also.
    }

    void unreparentClient()
    {
        immutable geo = geometry;
        infof("Frame to be removed is at (%s, %s)", geo.x, geo.y);

        xcb_reparent_window(connection, client.window, screen.root, geo.x, geo.y);
        xcb_change_save_set(connection, XCB_SET_MODE_DELETE, client.window);
    }

    void mapAll()
    {
        this.map();
        titlebar.map();
        client.map();
    }

    void focus(xcb_timestamp_t time = XCB_CURRENT_TIME)
    {
        xcb_set_input_focus(connection, XCB_INPUT_FOCUS_POINTER_ROOT, client.window, time);
    }

    void onFocused()
    {
        focused = true;
        immutable uint v = XCB_STACK_MODE_ABOVE;
        xcb_configure_window(connection, window, XCB_CONFIG_WINDOW_STACK_MODE, &v);
        draw();
    }

    void onUnforcused()
    {
        focused = false;
        draw();
    }

    void close(xcb_timestamp_t time = XCB_CURRENT_TIME)
    {
        void kill(in string reason)
        {
            warningf("%s: %#x", reason, client.window);
            infof("Fall back to killing %#x", client.window);
            client.kill();
        }

        auto atomProto = getAtomByName(connection, "WM_PROTOCOLS");
        auto atomDelWin = getAtomByName(connection, "WM_DELETE_WINDOW");
        xcb_icccm_get_wm_protocols_reply_t protocols;
        if (!xcb_icccm_get_wm_protocols_reply(connection, xcb_icccm_get_wm_protocols(connection, client.window,
                atomProto), &protocols, null))
        {
            kill("WM_PROTOCOLS is not supported");
            return;
        }
        import std.algorithm.searching : canFind;

        if (!protocols.atoms[0 .. protocols.atoms_len].canFind(atomDelWin))
        {
            kill("WM_DELETE_WINDOW is not supported");
            return;
        }

        infof("Let's send WM_DELETE_WINDOW to %#x", client.window);
        // dfmt off
        xcb_client_message_data_t clientMessageData = {
            data32: [atomDelWin, time, 0, 0, 0]
        };
        xcb_client_message_event_t clientMessageEvent = {
            response_type: XCB_CLIENT_MESSAGE,
            format : 32,
            window: client.window,
            type: atomProto,
            data: clientMessageData
        };
        // dfmt on
        xcb_send_event(connection, 0, client.window, XCB_EVENT_MASK_NO_EVENT, cast(char*)&clientMessageEvent);
    }

    void draw()
    {
        titlebar.draw(focused, titlebarAppearance);
    }
}

class Titlebar : Window
{
    this(Frame frame, Geometry geo)
    {
        frame.titlebar = this;
        auto titlebar = xcb_generate_id(frame.connection);
        super(frame, titlebar);
        uint[] values = [screen.white_pixel, XCB_EVENT_MASK_EXPOSURE];
        xcb_create_window(connection, XCB_COPY_FROM_PARENT, titlebar, frame.window, geo.x, geo.y, geo.width,
                geo.height, geo.borderWidth, XCB_WINDOW_CLASS_INPUT_OUTPUT, screen.root_visual,
                XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK, values.ptr);
        import std.conv : to;

        immutable titlebarName = "Titlebar in Frame " ~ frame.window.to!string(16);
        xcb_change_property(connection, XCB_PROP_MODE_APPEND, window, XCB_ATOM_WM_NAME, XCB_ATOM_STRING, 8,
                cast(uint) titlebarName.length, titlebarName.ptr);
    }

    void draw(bool focused, TitlebarAppearance app)
    {
        xcb_change_window_attributes(connection, window, XCB_CW_BACK_PIXEL, &(focused ? app.focusedBGColor : app.unfocusedBGColor));
        xcb_clear_area(connection, 0, window, 0, 0, 0, 0); // Fill the whole window with a new bg color
        immutable geo = geometry; ////
        immutable margin = ushort(3);
        const rect = xcb_rectangle_t(margin, margin, cast(ushort)(geo.width - margin * 2), cast(ushort)(geo.height - margin * 2));
        xcb_poly_fill_rectangle(connection, window, focused ? app.focusedGC : app.unfocusedGC, 1, &rect);
    }
}

struct TitlebarAppearance
{
    xcb_gcontext_t unfocusedGC;
    xcb_gcontext_t focusedGC;
    uint unfocusedBGColor;
    uint focusedBGColor;
    ushort height = 30;
    ushort minWidth = 120;
}
