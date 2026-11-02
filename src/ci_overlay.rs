// Concept Informatique (app client portable, Windows) : fonctions de session qui, dans RustDesk,
// demandent l'app installée en service ou lancée en administrateur.
//
// - Blocage du clavier et de la souris du client (« Mode Tech uniquement ») : BlockInput échoue sans
//   droits administrateur (erreur 1460). On utilise le crochet clavier/souris de RustDesk
//   (privacy_mode/win_input.rs), qui laisse passer ce que le technicien envoie et bloque le reste.
//   Ctrl+Alt+Suppr reste toujours disponible au client.
// - « Privacy » : une fenêtre noire plein écran, exclue de la capture (Windows 10 2004 et plus) : le
//   client voit un écran masqué avec un message, le technicien voit le bureau dessous. Elle laisse
//   passer les clics (le technicien travaille au travers) ; clavier et souris du client sont bloqués.
// - Fenêtre de connexion (gestionnaire de connexions) exclue de la capture : seul le client la voit.
//   Elle s'efface au passage du pointeur du technicien (ses clics vont dessous) ; ce pointeur est
//   montré au client par un halo à son prénom, lui aussi exclu de la capture.
use hbb_common::log;
use std::{
    sync::{
        atomic::{AtomicBool, AtomicI32, AtomicIsize, AtomicU32, Ordering},
        mpsc, Mutex,
    },
    time::Duration,
};
use winapi::{
    shared::{
        minwindef::{BOOL, DWORD, HINSTANCE, LPARAM, LRESULT, TRUE, UINT, WPARAM},
        windef::{HBRUSH, HDC, HWND, RECT},
    },
    um::winuser::*,
};

const WDA_EXCLUDEFROMCAPTURE: DWORD = 0x11;
const TIMER_TOPMOST: usize = 1;
const MESSAGE: &str = "Votre technicien Concept Informatique travaille sur votre PC.\n\n\
L'écran est masqué pour protéger vos informations, et le clavier et la souris sont momentanément \
désactivés pour éviter les fausses manœuvres.\n\nTout revient à la normale à la fin de l'intervention.\n\
En cas de doute : 069 57 59 11";

#[link(name = "gdi32")]
extern "system" {
    fn GetStockObject(i: i32) -> *mut std::ffi::c_void;
    fn SetTextColor(hdc: HDC, color: u32) -> u32;
    fn SetBkMode(hdc: HDC, mode: i32) -> i32;
    fn CreateFontW(
        h: i32,
        w: i32,
        esc: i32,
        orient: i32,
        weight: i32,
        italic: u32,
        underline: u32,
        strike: u32,
        charset: u32,
        out_prec: u32,
        clip_prec: u32,
        quality: u32,
        pitch: u32,
        face: *const u16,
    ) -> *mut std::ffi::c_void;
    fn SelectObject(hdc: HDC, obj: *mut std::ffi::c_void) -> *mut std::ffi::c_void;
    fn DeleteObject(obj: *mut std::ffi::c_void) -> i32;
    fn CreateSolidBrush(color: u32) -> *mut std::ffi::c_void;
    fn CreatePen(style: i32, width: i32, color: u32) -> *mut std::ffi::c_void;
    fn Ellipse(hdc: HDC, left: i32, top: i32, right: i32, bottom: i32) -> i32;
    fn RoundRect(hdc: HDC, left: i32, top: i32, right: i32, bottom: i32, w: i32, h: i32) -> i32;
}

#[link(name = "kernel32")]
extern "system" {
    fn GetModuleHandleW(name: *const u16) -> HINSTANCE;
    fn GetCurrentThreadId() -> u32;
    fn GetCurrentProcessId() -> u32;
    fn GetTickCount() -> u32;
}

static BLOCK: AtomicBool = AtomicBool::new(false);
static PRIVACY: AtomicBool = AtomicBool::new(false);
static PRIVACY_THREAD: AtomicU32 = AtomicU32::new(0);
static HOOKED: Mutex<bool> = Mutex::new(false);

/// App client Concept Informatique (réception seule), pas la version installée de RustDesk.
pub fn enabled() -> bool {
    hbb_common::config::is_incoming_only() && !crate::platform::is_installed()
}

fn update_hook() -> bool {
    let want = BLOCK.load(Ordering::SeqCst) || PRIVACY.load(Ordering::SeqCst);
    let mut hooked = HOOKED.lock().unwrap();
    if want && !*hooked {
        match crate::privacy_mode::win_input::hook() {
            Ok(()) => *hooked = true,
            Err(e) => log::warn!("Concept Informatique : blocage clavier/souris impossible : {e}"),
        }
    } else if !want && *hooked {
        if let Err(e) = crate::privacy_mode::win_input::unhook() {
            log::warn!("Concept Informatique : déblocage clavier/souris : {e}");
        }
        *hooked = false;
    }
    *hooked == want
}

/// Remplace BlockInput pour l'app client ; `None` hors app client (comportement d'origine).
pub fn block_input(on: bool) -> Option<(bool, String)> {
    if !enabled() {
        return None;
    }
    BLOCK.store(on, Ordering::SeqCst);
    Some(if update_hook() {
        (true, String::new())
    } else {
        (
            false,
            "Blocage du clavier et de la souris impossible sur ce PC".to_owned(),
        )
    })
}

/// Active ou retire l'écran « Privacy ».
pub fn privacy(on: bool) -> Result<(), String> {
    if on {
        if PRIVACY_THREAD.load(Ordering::SeqCst) == 0 {
            let (tx, rx) = mpsc::channel();
            std::thread::spawn(move || unsafe { privacy_window(tx) });
            match rx.recv_timeout(Duration::from_secs(5)) {
                Ok(Ok(())) => {}
                Ok(Err(e)) => return Err(e),
                Err(_) => return Err("La fenêtre Privacy ne s'est pas ouverte".to_owned()),
            }
        }
        PRIVACY.store(true, Ordering::SeqCst);
    } else {
        PRIVACY.store(false, Ordering::SeqCst);
        let thread = PRIVACY_THREAD.swap(0, Ordering::SeqCst);
        if thread != 0 {
            unsafe { PostThreadMessageW(thread, WM_QUIT, 0, 0) };
        }
    }
    update_hook();
    Ok(())
}

/// Fin de la connexion du technicien : le client retrouve toujours son PC.
pub fn on_connection_end() {
    if !enabled() {
        return;
    }
    BLOCK.store(false, Ordering::SeqCst);
    let _ = privacy(false);
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

unsafe fn virtual_screen() -> RECT {
    let x = GetSystemMetrics(SM_XVIRTUALSCREEN);
    let y = GetSystemMetrics(SM_YVIRTUALSCREEN);
    RECT {
        left: x,
        top: y,
        right: x + GetSystemMetrics(SM_CXVIRTUALSCREEN),
        bottom: y + GetSystemMetrics(SM_CYVIRTUALSCREEN),
    }
}

unsafe fn privacy_window(tx: mpsc::Sender<Result<(), String>>) {
    let class = wide("CiPrivacyWindow");
    let instance = GetModuleHandleW(std::ptr::null());
    let wc = WNDCLASSEXW {
        cbSize: std::mem::size_of::<WNDCLASSEXW>() as UINT,
        style: CS_HREDRAW | CS_VREDRAW,
        lpfnWndProc: Some(privacy_proc),
        cbClsExtra: 0,
        cbWndExtra: 0,
        hInstance: instance,
        hIcon: std::ptr::null_mut(),
        hCursor: std::ptr::null_mut(),
        hbrBackground: GetStockObject(4 /* BLACK_BRUSH */) as HBRUSH,
        lpszMenuName: std::ptr::null(),
        lpszClassName: class.as_ptr(),
        hIconSm: std::ptr::null_mut(),
    };
    RegisterClassExW(&wc); // déjà enregistrée à la 2e ouverture : sans conséquence
    let r = virtual_screen();
    let hwnd = CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE,
        class.as_ptr(),
        wide("Concept Informatique").as_ptr(),
        WS_POPUP,
        r.left,
        r.top,
        r.right - r.left,
        r.bottom - r.top,
        std::ptr::null_mut(),
        std::ptr::null_mut(),
        instance,
        std::ptr::null_mut(),
    );
    if hwnd.is_null() {
        let _ = tx.send(Err(format!(
            "Fenêtre Privacy : {}",
            std::io::Error::last_os_error()
        )));
        return;
    }
    SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA);
    if SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE) == 0 {
        // Sans exclusion de la capture, le technicien verrait aussi l'écran noir : on n'affiche rien.
        DestroyWindow(hwnd);
        let _ = tx.send(Err(
            "Privacy demande Windows 10 (version 2004) ou plus récent".to_owned(),
        ));
        return;
    }
    ShowWindow(hwnd, SW_SHOWNOACTIVATE);
    SetTimer(hwnd, TIMER_TOPMOST, 1000, None);
    PRIVACY_THREAD.store(GetCurrentThreadId(), Ordering::SeqCst);
    let _ = tx.send(Ok(()));

    let mut msg: MSG = std::mem::zeroed();
    while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    DestroyWindow(hwnd);
}

unsafe extern "system" fn privacy_proc(
    hwnd: HWND,
    msg: UINT,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        WM_TIMER => {
            // Reste au-dessus des autres fenêtres « toujours visibles » et suit les écrans branchés.
            let r = virtual_screen();
            SetWindowPos(
                hwnd,
                HWND_TOPMOST,
                r.left,
                r.top,
                r.right - r.left,
                r.bottom - r.top,
                SWP_NOACTIVATE,
            );
            0
        }
        WM_PAINT => {
            let mut ps: PAINTSTRUCT = std::mem::zeroed();
            let hdc = BeginPaint(hwnd, &mut ps);
            let mut rc: RECT = std::mem::zeroed();
            GetClientRect(hwnd, &mut rc);
            FillRect(hdc, &rc, GetStockObject(4) as HBRUSH);
            // Message centré sur l'écran principal
            let w = GetSystemMetrics(SM_CXSCREEN);
            let h = GetSystemMetrics(SM_CYSCREEN);
            let left = -GetSystemMetrics(SM_XVIRTUALSCREEN);
            let top = -GetSystemMetrics(SM_YVIRTUALSCREEN);
            let mut text_rc = RECT {
                left: left + w / 6,
                top: top + h / 3,
                right: left + w * 5 / 6,
                bottom: top + h,
            };
            let font = CreateFontW(
                -28,
                0,
                0,
                0,
                600,
                0,
                0,
                0,
                1,
                0,
                0,
                5,
                0,
                wide("Segoe UI").as_ptr(),
            );
            let old = SelectObject(hdc, font);
            SetTextColor(hdc, 0x00FFFFFF);
            SetBkMode(hdc, 1 /* TRANSPARENT */);
            let text = wide(MESSAGE);
            DrawTextW(
                hdc,
                text.as_ptr(),
                -1,
                &mut text_rc,
                DT_CENTER | DT_WORDBREAK,
            );
            SelectObject(hdc, old);
            DeleteObject(font);
            EndPaint(hwnd, &ps);
            0
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// Gestionnaire de connexions de l'app client : ses fenêtres sont exclues de la capture, le
/// technicien ne les voit pas (le client, si). Revu chaque seconde (fenêtres créées ou recréées).
/// Le pointeur du technicien, lui, est montré au client (halo à son prénom) et ne peut pas cliquer
/// dans la fenêtre : elle s'efface quand il passe dessus.
pub fn hide_cm_from_capture() {
    if !enabled() {
        return;
    }
    hbb_common::config::LocalConfig::set_option(TECH_NAME_OPTION.to_owned(), String::new());
    std::thread::spawn(|| loop {
        unsafe { EnumWindows(Some(exclude_own_window), 0) };
        std::thread::sleep(Duration::from_secs(1));
    });
    std::thread::spawn(|| unsafe { pointer_thread() });
}

unsafe extern "system" fn exclude_own_window(hwnd: HWND, _: LPARAM) -> BOOL {
    let mut pid: DWORD = 0;
    GetWindowThreadProcessId(hwnd, &mut pid);
    if pid == GetCurrentProcessId() && IsWindowVisible(hwnd) != 0 {
        let mut current: DWORD = 0;
        if GetWindowDisplayAffinity(hwnd, &mut current) != 0 && current != WDA_EXCLUDEFROMCAPTURE {
            SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
        }
        if hwnd as isize != HALO.load(Ordering::SeqCst) {
            let mut r: RECT = std::mem::zeroed();
            if GetWindowRect(hwnd, &mut r) != 0 && r.right - r.left > 100 {
                CM_WINDOW.store(hwnd as isize, Ordering::SeqCst);
            }
        }
    }
    TRUE
}

// ---------------------------------------------------------------- pointeur du technicien

const TECH_NAME_OPTION: &str = "ci-tech-name";
const WM_HALO_MOVE: UINT = WM_APP + 1;
const WM_HALO_HIDE: UINT = WM_APP + 2;
const TIMER_HALO: usize = 2;
const HALO_W: i32 = 190;
const HALO_H: i32 = 64;
const HOT: i32 = 22; // pointe du pointeur dans la fenêtre du halo
const KEY: u32 = 0x00FF00FF; // magenta : couleur transparente de la fenêtre du halo

static HALO: AtomicIsize = AtomicIsize::new(0);
static CM_WINDOW: AtomicIsize = AtomicIsize::new(0);
static CM_HIDDEN: AtomicBool = AtomicBool::new(false);
static IN_SESSION: AtomicBool = AtomicBool::new(false);
static MOVE_PENDING: AtomicBool = AtomicBool::new(false);
static LAST_X: AtomicI32 = AtomicI32::new(0);
static LAST_Y: AtomicI32 = AtomicI32::new(0);
static LAST_TECH_MOVE: AtomicU32 = AtomicU32::new(0);
static TECH_NAME: Mutex<String> = Mutex::new(String::new());

fn tick() -> u32 {
    unsafe { GetTickCount() }
}

unsafe fn pointer_thread() {
    let class = wide("CiTechPointer");
    let instance = GetModuleHandleW(std::ptr::null());
    let wc = WNDCLASSEXW {
        cbSize: std::mem::size_of::<WNDCLASSEXW>() as UINT,
        style: 0,
        lpfnWndProc: Some(halo_proc),
        cbClsExtra: 0,
        cbWndExtra: 0,
        hInstance: instance,
        hIcon: std::ptr::null_mut(),
        hCursor: std::ptr::null_mut(),
        hbrBackground: std::ptr::null_mut(),
        lpszMenuName: std::ptr::null(),
        lpszClassName: class.as_ptr(),
        hIconSm: std::ptr::null_mut(),
    };
    RegisterClassExW(&wc);
    let hwnd = CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE,
        class.as_ptr(),
        wide("Concept Informatique").as_ptr(),
        WS_POPUP,
        0,
        0,
        HALO_W,
        HALO_H,
        std::ptr::null_mut(),
        std::ptr::null_mut(),
        instance,
        std::ptr::null_mut(),
    );
    if hwnd.is_null() {
        log::warn!(
            "Concept Informatique : halo du technicien : {}",
            std::io::Error::last_os_error()
        );
        return;
    }
    SetLayeredWindowAttributes(hwnd, KEY, 0, LWA_COLORKEY);
    SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
    HALO.store(hwnd as isize, Ordering::SeqCst);
    SetTimer(hwnd, TIMER_HALO, 300, None);
    let hook = SetWindowsHookExW(WH_MOUSE_LL, Some(mouse_proc), instance, 0);
    if hook.is_null() {
        log::warn!(
            "Concept Informatique : suivi du pointeur : {}",
            std::io::Error::last_os_error()
        );
    }
    let mut msg: MSG = std::mem::zeroed();
    while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    if !hook.is_null() {
        UnhookWindowsHookEx(hook);
    }
}

/// Appelé pour chaque évènement souris du PC : rien de lourd ici, tout passe par des messages.
unsafe extern "system" fn mouse_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION && IN_SESSION.load(Ordering::Relaxed) {
        let info = &*(lparam as *const MSLLHOOKSTRUCT);
        let halo = HALO.load(Ordering::Relaxed) as HWND;
        if info.flags & LLMHF_INJECTED != 0 {
            LAST_X.store(info.pt.x, Ordering::Relaxed);
            LAST_Y.store(info.pt.y, Ordering::Relaxed);
            LAST_TECH_MOVE.store(tick(), Ordering::Relaxed);
            if !MOVE_PENDING.swap(true, Ordering::Relaxed) {
                PostMessageW(halo, WM_HALO_MOVE, 0, 0);
            }
        } else if wparam as UINT == WM_MOUSEMOVE || wparam as UINT == WM_LBUTTONDOWN {
            PostMessageW(halo, WM_HALO_HIDE, 0, 0);
        }
    }
    CallNextHookEx(std::ptr::null_mut(), code, wparam, lparam)
}

/// La fenêtre de connexion s'efface quand le pointeur du technicien passe dessus : ses clics vont
/// à ce qui est dessous. Elle revient dès qu'il s'éloigne ou que le client reprend sa souris.
unsafe fn update_cm(x: i32, y: i32, tech: bool) {
    let cm = CM_WINDOW.load(Ordering::SeqCst) as HWND;
    if cm.is_null() {
        return;
    }
    let mut r: RECT = std::mem::zeroed();
    GetWindowRect(cm, &mut r);
    let near =
        tech && x >= r.left - 24 && x <= r.right + 24 && y >= r.top - 24 && y <= r.bottom + 24;
    if near != CM_HIDDEN.swap(near, Ordering::SeqCst) {
        ShowWindowAsync(cm, if near { SW_HIDE } else { SW_SHOWNOACTIVATE });
    }
}

unsafe extern "system" fn halo_proc(
    hwnd: HWND,
    msg: UINT,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        WM_HALO_MOVE => {
            MOVE_PENDING.store(false, Ordering::Relaxed);
            let (x, y) = (
                LAST_X.load(Ordering::Relaxed),
                LAST_Y.load(Ordering::Relaxed),
            );
            update_cm(x, y, true);
            SetWindowPos(
                hwnd,
                HWND_TOPMOST,
                x - HOT,
                y - HOT,
                HALO_W,
                HALO_H,
                SWP_NOACTIVATE | SWP_SHOWWINDOW,
            );
            0
        }
        WM_HALO_HIDE => {
            update_cm(0, 0, false);
            ShowWindow(hwnd, SW_HIDE);
            0
        }
        WM_TIMER => {
            let name = hbb_common::config::LocalConfig::get_option(TECH_NAME_OPTION);
            IN_SESSION.store(!name.is_empty(), Ordering::Relaxed);
            let changed = {
                let mut current = TECH_NAME.lock().unwrap();
                let changed = *current != name;
                *current = name.clone();
                changed
            };
            if changed {
                InvalidateRect(hwnd, std::ptr::null(), TRUE);
            }
            // Technicien immobile depuis 4 s : le halo s'efface et l'overlay revient chez le client.
            if name.is_empty() || tick().wrapping_sub(LAST_TECH_MOVE.load(Ordering::Relaxed)) > 4000
            {
                ShowWindow(hwnd, SW_HIDE);
                update_cm(0, 0, false);
            }
            0
        }
        WM_PAINT => {
            let mut ps: PAINTSTRUCT = std::mem::zeroed();
            let hdc = BeginPaint(hwnd, &mut ps);
            let mut rc: RECT = std::mem::zeroed();
            GetClientRect(hwnd, &mut rc);
            let key = CreateSolidBrush(KEY);
            FillRect(hdc, &rc, key as HBRUSH);
            DeleteObject(key);
            // Anneau turquoise autour de la pointe du pointeur
            let pen = CreatePen(0 /* PS_SOLID */, 3, 0x00BFD42D);
            let old_pen = SelectObject(hdc, pen);
            let old_brush = SelectObject(hdc, GetStockObject(5 /* NULL_BRUSH */));
            Ellipse(hdc, HOT - 18, HOT - 18, HOT + 18, HOT + 18);
            SelectObject(hdc, old_brush);
            SelectObject(hdc, old_pen);
            DeleteObject(pen);
            // Étiquette au prénom du technicien
            let name = TECH_NAME.lock().unwrap().clone();
            if !name.is_empty() {
                let label = wide(&name);
                let font = CreateFontW(
                    -13,
                    0,
                    0,
                    0,
                    700,
                    0,
                    0,
                    0,
                    1,
                    0,
                    0,
                    5,
                    0,
                    wide("Segoe UI").as_ptr(),
                );
                let old_font = SelectObject(hdc, font);
                let mut text_rc = RECT {
                    left: 0,
                    top: 0,
                    right: 0,
                    bottom: 0,
                };
                DrawTextW(
                    hdc,
                    label.as_ptr(),
                    -1,
                    &mut text_rc,
                    DT_CALCRECT | DT_SINGLELINE,
                );
                let w = (text_rc.right - text_rc.left).min(HALO_W - HOT - 22);
                let mut pill = RECT {
                    left: HOT + 12,
                    top: HOT + 14,
                    right: HOT + 12 + w + 18,
                    bottom: HOT + 14 + 22,
                };
                let fill = CreateSolidBrush(0x00788503);
                let old_brush = SelectObject(hdc, fill);
                let old_pen = SelectObject(hdc, GetStockObject(8 /* NULL_PEN */));
                RoundRect(hdc, pill.left, pill.top, pill.right, pill.bottom, 20, 20);
                SelectObject(hdc, old_pen);
                SelectObject(hdc, old_brush);
                DeleteObject(fill);
                SetTextColor(hdc, 0x00FFFFFF);
                SetBkMode(hdc, 1 /* TRANSPARENT */);
                DrawTextW(
                    hdc,
                    label.as_ptr(),
                    -1,
                    &mut pill,
                    DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
                );
                SelectObject(hdc, old_font);
                DeleteObject(font);
            }
            EndPaint(hwnd, &ps);
            0
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
