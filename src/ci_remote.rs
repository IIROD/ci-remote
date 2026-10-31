// Concept Informatique : rattachement du PC au compte client.
//
// Le site fournit l'app sous un nom de fichier contenant un code de téléchargement à usage
// unique (« …dl-<26 caractères base32>….exe »). L'app l'envoie avec sa présence ; le serveur
// rattache alors le PC (ID + identifiant machine) au compte qui a téléchargé l'app.
use hbb_common::config::LocalConfig;

const OPTION_DOWNLOAD_TOKEN: &str = "ci-download-token";
const TOKEN_LEN: usize = 26;

pub fn download_token() -> String {
    let stored = LocalConfig::get_option(OPTION_DOWNLOAD_TOKEN);
    match parse_token(&exe_name()) {
        Some(token) => {
            if token != stored {
                LocalConfig::set_option(OPTION_DOWNLOAD_TOKEN.to_owned(), token.clone());
            }
            token
        }
        None => stored,
    }
}

fn exe_name() -> String {
    // Version portable : le nom du fichier téléchargé est transmis par le lanceur.
    if let Ok(name) = std::env::var(crate::common::PORTABLE_APPNAME_RUNTIME_ENV_KEY) {
        return name;
    }
    std::env::current_exe()
        .ok()
        .and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()))
        .unwrap_or_default()
}

fn parse_token(name: &str) -> Option<String> {
    let upper = name.to_uppercase();
    let start = upper.rfind("DL-")? + 3;
    let token: String = upper[start..]
        .chars()
        .take_while(|c| c.is_ascii_uppercase() || ('2'..='7').contains(c))
        .collect();
    (token.len() == TOKEN_LEN).then_some(token)
}

#[cfg(test)]
mod tests {
    use super::parse_token;

    const T: &str = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";

    #[test]
    fn token_from_download_name() {
        assert_eq!(
            parse_token(&format!("ci-remote_dl-{T}.exe")),
            Some(T.to_owned())
        );
        assert_eq!(
            parse_token(&format!(
                "C:\\Users\\x\\Downloads\\ci-remote_dl-{} (1).exe",
                T.to_lowercase()
            )),
            Some(T.to_owned())
        );
    }

    #[test]
    fn no_token() {
        assert_eq!(parse_token("ci-remote.exe"), None);
        assert_eq!(parse_token("ci-remote_dl-ABC.exe"), None);
        assert_eq!(parse_token(&format!("ci-remote_dl-{T}A.exe")), None);
    }
}
