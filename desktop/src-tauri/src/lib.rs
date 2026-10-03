pub mod client;

#[cfg(feature = "desktop")]
mod app {
    use super::client::Connection;
    use serde_json::Value;

    #[tauri::command]
    async fn connect_server(
        state: tauri::State<'_, Connection>,
        endpoint: String,
        username: String,
        password: String,
        certificate_pem: String,
    ) -> Result<String, String> {
        state
            .connect(&endpoint, &username, password, &certificate_pem)
            .await
    }

    #[tauri::command]
    fn disconnect_server(state: tauri::State<'_, Connection>) {
        state.disconnect();
    }

    #[tauri::command]
    async fn api_request(
        state: tauri::State<'_, Connection>,
        path: String,
        method: String,
        body: Option<Value>,
    ) -> Result<Value, String> {
        state.request(&path, &method, body).await
    }

    pub fn run() {
        tauri::Builder::default()
            .manage(Connection::default())
            .setup(|app| {
                tauri::WebviewWindowBuilder::from_config(app, &app.config().app.windows[0])?
                    .on_navigation(|url| {
                        (url.scheme() == "tauri" && url.host_str() == Some("localhost"))
                            || (matches!(url.scheme(), "http" | "https")
                                && url.host_str() == Some("tauri.localhost"))
                            || (cfg!(debug_assertions)
                                && url.scheme() == "http"
                                && matches!(url.host_str(), Some("localhost" | "127.0.0.1"))
                                && url.port() == Some(5173))
                    })
                    .build()?;
                Ok(())
            })
            .invoke_handler(tauri::generate_handler![
                connect_server,
                disconnect_server,
                api_request
            ])
            .run(tauri::generate_context!())
            .expect("desktop initialization failed");
    }
}

#[cfg(feature = "desktop")]
pub use app::run;
