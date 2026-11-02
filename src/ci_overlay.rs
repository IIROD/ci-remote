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
use hbb_common::log;
use std::{
    sync::{
        atomic::{AtomicBool, AtomicU32, Ordering},
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
        h: i32, w: i32, esc: i32, orient: i32, weight: i32, italic: u32, underline: u32, strike: u32,
        charset: u32, out_prec: u32, clip_prec: u32, quality: u32, pitch: u32, face: *const u16,
    ) -> *mut std::ffi::c_void;
    fn SelectObject(hdc: HDC, obj: *mut std::ffi::c_void) -> *mut std::ffi::c_void;
    fn DeleteObject(obj: *mut std::ffi::c_void) -> i32;
}

#[link(name = "kernel32")]
extern "system" {
    fn GetModuleHandleW(name: *const u16) -> HINSTANCE;
    fn GetCurrentThreadId() -> u32;
    fn GetCurrentProcessId() -> u32;
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
        (false, "Blocage du clavier et de la souris impossible sur ce PC".to_owned())
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
    RECT { left: x, top: y, right: x + GetSystemMetrics(SM_CXVIRTUALSCREEN), bottom: y + GetSystemMetrics(SM_CYVIRTUALSCREEN) }
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
        let _ = tx.send(Err(format!("Fenêtre Privacy : {}", std::io::Error::last_os_error())));
        return;
    }
    SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA);
    if SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE) == 0 {
        // Sans exclusion de la capture, le technicien verrait aussi l'écran noir : on n'affiche rien.
        DestroyWindow(hwnd);
        let _ = tx.send(Err("Privacy demande Windows 10 (version 2004) ou plus récent".to_owned()));
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

unsafe extern "system" fn privacy_proc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_TIMER => {
            // Reste au-dessus des autres fenêtres « toujours visibles » et suit les écrans branchés.
            let r = virtual_screen();
            SetWindowPos(hwnd, HWND_TOPMOST, r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_NOACTIVATE);
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
            let mut text_rc = RECT { left: left + w / 6, top: top + h / 3, right: left + w * 5 / 6, bottom: top + h };
            let font = CreateFontW(-28, 0, 0, 0, 600, 0, 0, 0, 1, 0, 0, 5, 0, wide("Segoe UI").as_ptr());
            let old = SelectObject(hdc, font);
            SetTextColor(hdc, 0x00FFFFFF);
            SetBkMode(hdc, 1 /* TRANSPARENT */);
            let text = wide(MESSAGE);
            DrawTextW(hdc, text.as_ptr(), -1, &mut text_rc, DT_CENTER | DT_WORDBREAK);
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
pub fn hide_cm_from_capture() {
    if !enabled() {
        return;
    }
    std::thread::spawn(|| loop {
        unsafe { EnumWindows(Some(exclude_own_window), 0) };
        std::thread::sleep(Duration::from_secs(1));
    });
}

unsafe extern "system" fn exclude_own_window(hwnd: HWND, _: LPARAM) -> BOOL {
    let mut pid: DWORD = 0;
    GetWindowThreadProcessId(hwnd, &mut pid);
    if pid == GetCurrentProcessId() && IsWindowVisible(hwnd) != 0 {
        let mut current: DWORD = 0;
        if GetWindowDisplayAffinity(hwnd, &mut current) != 0 && current != WDA_EXCLUDEFROMCAPTURE {
            SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
        }
    }
    TRUE
}
