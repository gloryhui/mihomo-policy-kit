use reqwest::{Client, Method, StatusCode};
use serde_json::Value;
use std::{
    sync::{Arc, Mutex},
    time::Duration,
};
use url::Url;
use zeroize::Zeroizing;

const MAX_RESPONSE: usize = 16 * 1024 * 1024;
const MAX_REQUEST: usize = 11 * 1024 * 1024;
const CHANGED: &str = "连接已改变，请重新操作";

struct Session {
    origin: Url,
    client: Client,
    username: String,
    password: Zeroizing<String>,
    generation: u64,
}

#[derive(Default)]
struct Inner {
    generation: u64,
    session: Option<Arc<Session>>,
}

#[derive(Default)]
pub struct Connection(Mutex<Inner>);

pub fn origin(endpoint: &str) -> Result<Url, String> {
    let url = Url::parse(endpoint.trim()).map_err(|_| "请输入有效的服务器地址")?;
    let loopback = match url.host() {
        Some(url::Host::Domain("localhost")) => true,
        Some(url::Host::Ipv4(ip)) => ip.is_loopback(),
        Some(url::Host::Ipv6(ip)) => ip.is_loopback(),
        _ => false,
    };
    if url.host().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.path() != "/"
        || url.query().is_some()
        || url.fragment().is_some()
        || (url.scheme() != "https" && !(url.scheme() == "http" && loopback))
    {
        return Err(
            "服务器地址必须是 HTTPS 根地址（本机开发可用 HTTP），不能包含账号、路径或参数".into(),
        );
    }
    Ok(url)
}

fn route(path: &str, method: &str) -> Result<(), String> {
    let lower = path.to_ascii_lowercase();
    if path.len() > 4096
        || path.contains(['\\', '#'])
        || path.chars().any(char::is_control)
        || lower.contains("%2f")
        || lower.contains("%5c")
        || lower.contains("%2e")
    {
        return Err("无效的管理 API 路径".into());
    }
    let (bare, query) = path.split_once('?').unwrap_or((path, ""));
    let segments: Vec<_> = bare.split('/').collect();
    if segments
        .iter()
        .any(|x| x.is_empty() || *x == "." || *x == "..")
    {
        return Err("无效的管理 API 路径".into());
    }
    let id = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    let permitted = match segments.as_slice() {
        ["health" | "dashboard" | "builds"] => method == "GET",
        ["sources" | "profiles"] => matches!(method, "GET" | "POST"),
        ["nodes"] => method == "GET",
        ["sources" | "profiles", number] if id(number) => matches!(method, "PATCH" | "DELETE"),
        ["sources", number, "refresh"] | ["profiles", number, "build"] if id(number) => {
            method == "POST"
        }
        ["nodes", number, "selection"] if id(number) => method == "PATCH",
        ["nodes", "batch-selection"] => method == "POST",
        ["publisher", "status"] => method == "GET",
        ["publisher", "publish" | "rollback"] => method == "POST",
        ["publisher", "tokens"] => matches!(method, "GET" | "POST"),
        ["publisher", "tokens", _] => method == "DELETE",
        _ => false,
    };
    let query_allowed = query.is_empty()
        || (bare == "nodes"
            && method == "GET"
            && url::form_urlencoded::parse(query.as_bytes()).all(|(key, _)| {
                [
                    "profile_id",
                    "q",
                    "source_id",
                    "region",
                    "max_multiplier",
                    "unknown_multiplier",
                    "available",
                    "page",
                    "per_page",
                ]
                .contains(&key.as_ref())
            }));
    if !permitted || !query_allowed {
        return Err("不支持的管理 API 请求".into());
    }
    Ok(())
}

fn http_error(status: StatusCode) -> String {
    match status.as_u16() {
        401 => "认证失败，请检查用户名和密码",
        403 => "服务器拒绝请求，请检查公开地址及访问权限",
        404 => "服务器接口不存在，请检查地址和服务版本",
        400 | 413 | 415 | 422 => "请求未被接受，请检查输入和文件大小",
        _ => "服务器操作失败，请检查订阅、构建和服务状态",
    }
    .into()
}

impl Session {
    async fn send(&self, path: &str, method: &str, body: Option<Value>) -> Result<Value, String> {
        route(path, method)?;
        let url = Url::parse(&format!("{}api/v1/{}", self.origin, path))
            .map_err(|_| "无效的管理 API 路径")?;
        if url.origin() != self.origin.origin() || !url.path().starts_with("/api/v1/") {
            return Err("无效的管理 API 路径".into());
        }
        let method = Method::from_bytes(method.as_bytes()).map_err(|_| "无效的请求方法")?;
        let mut request = self
            .client
            .request(method, url)
            .basic_auth(&self.username, Some(self.password.as_str()))
            .header("X-MPK-Request", "1")
            .header("Cache-Control", "no-store");
        if let Some(body) = body {
            let bytes = serde_json::to_vec(&body).map_err(|_| "无效的请求内容")?;
            if bytes.len() > MAX_REQUEST {
                return Err("请求内容过大".into());
            }
            request = request
                .header("Content-Type", "application/json")
                .body(bytes);
        }
        let mut response = request
            .send()
            .await
            .map_err(|_| "无法连接服务器，请检查网络、地址和证书")?;
        if !response.status().is_success() {
            return Err(http_error(response.status()));
        }
        if response
            .content_length()
            .is_some_and(|n| n > MAX_RESPONSE as u64)
        {
            return Err("服务器响应过大".into());
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| "服务器响应中断，请重试")?
        {
            if bytes.len() + chunk.len() > MAX_RESPONSE {
                return Err("服务器响应过大".into());
            }
            bytes.extend_from_slice(&chunk);
        }
        serde_json::from_slice(&bytes)
            .map_err(|_| "服务器返回了无效的 JSON，请检查地址和服务版本".into())
    }
}

impl Connection {
    pub fn disconnect(&self) {
        let mut inner = self.0.lock().unwrap();
        inner.generation += 1;
        inner.session = None;
    }

    pub async fn connect(
        &self,
        endpoint: &str,
        username: &str,
        password: String,
        certificate: &str,
    ) -> Result<String, String> {
        let password = Zeroizing::new(password);
        let generation = {
            let mut inner = self.0.lock().unwrap();
            inner.generation += 1;
            inner.session = None;
            inner.generation
        };
        let origin = origin(endpoint)?;
        if username.is_empty()
            || username.len() > 256
            || username.contains(':')
            || username.chars().any(char::is_control)
            || password.is_empty()
            || password.len() > 4096
        {
            return Err("请输入有效的用户名和密码".into());
        }
        let mut builder = Client::builder()
            .https_only(origin.scheme() == "https")
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(15))
            .timeout(Duration::from_secs(300))
            .no_proxy();
        if !certificate.is_empty() {
            if certificate.len() > 131072 || certificate.contains("PRIVATE KEY") {
                return Err("请导入不超过 128 KB 的公开 PEM 证书".into());
            }
            let certs = reqwest::Certificate::from_pem_bundle(certificate.as_bytes())
                .map_err(|_| "无法读取公开 PEM 证书")?;
            if certs.is_empty() {
                return Err("证书文件中没有公开证书".into());
            }
            for cert in certs {
                builder = builder.add_root_certificate(cert);
            }
        }
        let session = Arc::new(Session {
            origin,
            client: builder.build().map_err(|_| "无法初始化安全连接")?,
            username: username.into(),
            password,
            generation,
        });
        let health = session.send("health", "GET", None).await?;
        if health["status"] != "ok" || health["schema_version"] != 1 {
            return Err("服务器版本不兼容，请使用 V0.5 控制台 API".into());
        }
        let label = session.origin.as_str().trim_end_matches('/').to_string();
        let mut inner = self.0.lock().unwrap();
        if inner.generation != generation {
            return Err(CHANGED.into());
        }
        inner.session = Some(session);
        Ok(label)
    }

    pub async fn request(
        &self,
        path: &str,
        method: &str,
        body: Option<Value>,
    ) -> Result<Value, String> {
        let session = self
            .0
            .lock()
            .unwrap()
            .session
            .clone()
            .ok_or("请先连接服务器")?;
        let result = session.send(path, method, body).await;
        if self.0.lock().unwrap().generation != session.generation {
            return Err(CHANGED.into());
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{Read, Write},
        net::TcpListener,
        thread,
    };

    fn fixture(replies: Vec<&'static str>) -> (String, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        let handle = thread::spawn(move || {
            for reply in replies {
                let (mut socket, _) = listener.accept().unwrap();
                socket
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let mut bytes = Vec::new();
                let mut buffer = [0; 1024];
                while !bytes.windows(4).any(|x| x == b"\r\n\r\n") {
                    let n = socket.read(&mut buffer).unwrap();
                    assert!(n > 0);
                    bytes.extend_from_slice(&buffer[..n]);
                }
                let request = String::from_utf8(bytes).unwrap().to_ascii_lowercase();
                assert!(request.contains("authorization: basic "));
                assert!(request.contains("x-mpk-request: 1"));
                assert!(request.starts_with("get /api/v1/"));
                socket.write_all(reply.as_bytes()).unwrap();
            }
        });
        (endpoint, handle)
    }
    const HEALTH: &str = "HTTP/1.1 200 OK\r\nContent-Length: 34\r\nConnection: close\r\n\r\n{\"status\":\"ok\",\"schema_version\":1}";

    #[test]
    fn endpoint_security() {
        for valid in [
            "https://example.invalid:8215",
            "http://127.0.0.1:9292",
            "http://[::1]:9292",
            "http://localhost:9292",
        ] {
            assert!(origin(valid).is_ok());
        }
        for bad in [
            "http://example.invalid",
            "file:///tmp",
            "https://user:password@example.invalid",
            "https://example.invalid/api",
            "https://example.invalid/?token=fake",
            "https://example.invalid/#x",
        ] {
            assert!(origin(bad).is_err());
        }
    }
    #[test]
    fn request_scope() {
        for bad in [
            "https://evil.invalid",
            "//evil.invalid",
            "../sub/fake",
            "sources/../health",
            "sources/%2e%2e/health",
            "publisher/tokens/a%2fb",
            "health?url=x",
        ] {
            assert!(route(bad, "GET").is_err());
        }
        assert!(route("publisher/publish", "GET").is_err());
        assert!(route("nodes?q=%E4%B8%AD%E6%96%87&page=2", "GET").is_ok());
        assert!(route("publisher/tokens/%E4%B8%AD%E6%96%87", "DELETE").is_ok());
        assert!(route("sources/1/refresh", "POST").is_ok());
    }
    #[tokio::test]
    async fn authentication_and_disconnect() {
        let (endpoint, handle) = fixture(vec![
            HEALTH,
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n[]",
        ]);
        let state = Connection::default();
        state
            .connect(&endpoint, "fixture", "fake-password".into(), "")
            .await
            .unwrap();
        assert_eq!(
            state.request("sources", "GET", None).await.unwrap(),
            serde_json::json!([])
        );
        state.disconnect();
        assert!(state.request("sources", "GET", None).await.is_err());
        handle.join().unwrap();
    }
    #[tokio::test]
    async fn credentials_never_follow_redirects_or_enter_errors() {
        for reply in ["HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/SECRET\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            "HTTP/1.1 401 Unauthorized\r\nContent-Length: 6\r\nConnection: close\r\n\r\nSECRET"] {
            let (endpoint, handle) = fixture(vec![reply]);
            let state = Connection::default();
            let error = state.connect(&endpoint, "fixture", "SECRET".into(), "").await.unwrap_err();
            assert!(!error.contains("SECRET"));
            assert!(state.request("sources", "GET", None).await.is_err());
            handle.join().unwrap();
        }
    }
    #[tokio::test]
    async fn certificate_validation_cannot_be_disabled() {
        let state = Connection::default();
        assert!(state
            .connect(
                "https://example.invalid",
                "fixture",
                "fake".into(),
                "invalid pem"
            )
            .await
            .is_err());
        assert!(state
            .connect(
                "https://example.invalid",
                "fixture",
                "fake".into(),
                "-----BEGIN PRIVATE KEY-----"
            )
            .await
            .is_err());
    }

    #[tokio::test]
    async fn tls_requires_explicit_trust_and_matching_hostname() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio_rustls::{rustls, TlsAcceptor};
        let generated = rcgen::generate_simple_self_signed(vec!["localhost".into()]).unwrap();
        let pem = generated.cert.pem();
        let key =
            rustls::pki_types::PrivatePkcs8KeyDer::from(generated.signing_key.serialize_der());
        let config = rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(vec![generated.cert.der().clone()], key.into())
            .unwrap();
        let acceptor = TlsAcceptor::from(Arc::new(config));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            for _ in 0..3 {
                let (socket, _) = listener.accept().await.unwrap();
                if let Ok(mut stream) = acceptor.accept(socket).await {
                    let mut buffer = [0; 2048];
                    stream.read(&mut buffer).await.unwrap();
                    stream.write_all(HEALTH.as_bytes()).await.unwrap();
                    stream.shutdown().await.unwrap();
                }
            }
        });
        let state = Connection::default();
        let endpoint = format!("https://localhost:{port}");
        assert!(state
            .connect(&endpoint, "fixture", "fake".into(), "")
            .await
            .is_err());
        state
            .connect(&endpoint, "fixture", "fake".into(), &pem)
            .await
            .unwrap();
        assert!(state
            .connect(
                &format!("https://127.0.0.1:{port}"),
                "fixture",
                "fake".into(),
                &pem
            )
            .await
            .is_err());
        server.await.unwrap();
    }

    #[tokio::test]
    async fn stale_response_is_discarded_after_disconnect() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        let (ready, received) = tokio::sync::oneshot::channel();
        let (release, wait) = std::sync::mpsc::channel();
        let handle = thread::spawn(move || {
            let (mut first, _) = listener.accept().unwrap();
            let mut buffer = [0; 2048];
            first.read(&mut buffer).unwrap();
            first.write_all(HEALTH.as_bytes()).unwrap();
            drop(first);
            let (mut second, _) = listener.accept().unwrap();
            second.read(&mut buffer).unwrap();
            ready.send(()).unwrap();
            wait.recv_timeout(Duration::from_secs(5)).unwrap();
            second
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n[]")
                .unwrap();
        });
        let state = Arc::new(Connection::default());
        state
            .connect(&endpoint, "fixture", "fake".into(), "")
            .await
            .unwrap();
        let pending_state = state.clone();
        let pending =
            tokio::spawn(async move { pending_state.request("sources", "GET", None).await });
        received.await.unwrap();
        state.disconnect();
        release.send(()).unwrap();
        assert_eq!(pending.await.unwrap().unwrap_err(), CHANGED);
        handle.join().unwrap();
    }

    #[tokio::test]
    async fn invalid_and_oversized_responses_are_rejected() {
        for reply in [
            "HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\nSECRET",
            "HTTP/1.1 200 OK\r\nContent-Length: 16777217\r\nConnection: close\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}",
        ] {
            let (endpoint, handle) = fixture(vec![reply]);
            let state = Connection::default();
            let error = state
                .connect(&endpoint, "fixture", "fake".into(), "")
                .await
                .unwrap_err();
            assert!(!error.contains("SECRET"));
            handle.join().unwrap();
        }
    }

    #[tokio::test]
    async fn oversized_request_is_rejected_before_network_io() {
        let (endpoint, handle) = fixture(vec![HEALTH]);
        let state = Connection::default();
        state
            .connect(&endpoint, "fixture", "fake".into(), "")
            .await
            .unwrap();
        handle.join().unwrap();
        assert_eq!(
            state
                .request(
                    "sources",
                    "POST",
                    Some(serde_json::json!({"content": "a".repeat(MAX_REQUEST)}))
                )
                .await
                .unwrap_err(),
            "请求内容过大"
        );
    }
}
