use hbb_common::{
    anyhow::{anyhow, Context},
    config::{
        active_peer_profile, set_active_peer_profile, ServerProfile, ServerProfileStore,
        ServerProfilesConfig,
    },
    ResultType,
};
use serde_derive::Serialize;
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::Mutex,
};

const RENDEZVOUS_SERVER_OPTION: &str = "custom-rendezvous-server";
const KEY_OPTION: &str = "key";
const RELAY_SERVER_OPTION: &str = "relay-server";
const API_SERVER_OPTION: &str = "api-server";
const SERIALIZATION_ERROR_JSON: &str =
    r#"{"ok":false,"error":"failed to serialize server profile response","config":null}"#;

lazy_static::lazy_static! {
    static ref MANAGER: Mutex<ManagerState> = Mutex::new(ManagerState::default());
}

trait ProfileStore: Send + Sync {
    fn identity(&self) -> PathBuf;
    fn load_or_migrate(&self, id_server: &str, key: &str) -> ResultType<ServerProfilesConfig>;
    fn recover_from_options(&self, id_server: &str, key: &str) -> ResultType<ServerProfilesConfig>;
    fn save(&self, config: &ServerProfilesConfig) -> ResultType<()>;
    fn remove_profile_transaction(
        &self,
        current: &ServerProfilesConfig,
        id: &str,
    ) -> ResultType<ServerProfilesConfig>;
}

impl ProfileStore for ServerProfileStore {
    fn identity(&self) -> PathBuf {
        self.root().to_owned()
    }

    fn load_or_migrate(&self, id_server: &str, key: &str) -> ResultType<ServerProfilesConfig> {
        self.load_or_migrate(id_server, key)
    }

    fn recover_from_options(&self, id_server: &str, key: &str) -> ResultType<ServerProfilesConfig> {
        self.recover_from_options(id_server, key)
    }

    fn save(&self, config: &ServerProfilesConfig) -> ResultType<()> {
        self.save(config)
    }

    fn remove_profile_transaction(
        &self,
        current: &ServerProfilesConfig,
        id: &str,
    ) -> ResultType<ServerProfilesConfig> {
        self.remove_profile_transaction(current, id)
    }
}

trait OptionsBackend: Send + Sync {
    fn current(&self) -> ResultType<HashMap<String, String>>;
    fn apply(&self, options: HashMap<String, String>) -> ResultType<()>;
}

struct ProductionOptions;

impl OptionsBackend for ProductionOptions {
    fn current(&self) -> ResultType<HashMap<String, String>> {
        crate::ipc::get_options_confirmed()
    }

    fn apply(&self, options: HashMap<String, String>) -> ResultType<()> {
        crate::ipc::set_options_confirmed(options)
    }
}

trait ActiveProfileBackend: Send + Sync {
    fn current(&self) -> String;
    fn set(&self, id: &str) -> ResultType<()>;
}

struct ProductionActiveProfile;

impl ActiveProfileBackend for ProductionActiveProfile {
    fn current(&self) -> String {
        active_peer_profile()
    }

    fn set(&self, id: &str) -> ResultType<()> {
        set_active_peer_profile(id)
    }
}

struct ServerProfileManager {
    store: Box<dyn ProfileStore>,
    options: Box<dyn OptionsBackend>,
    runtime: Box<dyn ActiveProfileBackend>,
    config: ServerProfilesConfig,
    health: ManagerHealth,
}

enum ManagerHealth {
    Healthy,
    Degraded(String),
}

#[derive(Default)]
struct ManagerState {
    root: Option<PathBuf>,
    manager: Option<ServerProfileManager>,
    init_error: Option<String>,
}

impl ManagerState {
    fn ensure_root(&mut self, requested: &Path) -> ResultType<()> {
        match self.root.as_deref() {
            Some(existing) if existing != requested => {
                let error =
                    "server profile manager was initialized for a different configuration root";
                self.manager = None;
                self.init_error = Some(error.to_owned());
                Err(anyhow!(error))
            }
            Some(_) => Ok(()),
            None => {
                self.root = Some(requested.to_owned());
                Ok(())
            }
        }
    }

    fn unavailable_response(&self) -> String {
        response_json_parts(
            false,
            self.init_error
                .clone()
                .unwrap_or_else(|| "server profile manager is not initialized".to_owned()),
            None,
        )
    }

    fn finish_initialization(
        &mut self,
        result: ResultType<ServerProfileManager>,
        key: &str,
    ) -> ResultType<ServerProfilesConfig> {
        match result {
            Ok(manager) => {
                let snapshot = manager.snapshot();
                self.manager = Some(manager);
                self.init_error = None;
                Ok(snapshot)
            }
            Err(error) => {
                let safe = safe_initialization_error(&error, key);
                self.manager = None;
                self.init_error = Some(safe.clone());
                Err(anyhow!(safe))
            }
        }
    }
}

impl ServerProfileManager {
    fn initialize_with_dependencies(
        store: Box<dyn ProfileStore>,
        options: Box<dyn OptionsBackend>,
        runtime: Box<dyn ActiveProfileBackend>,
        id_server: &str,
        key: &str,
    ) -> ResultType<Self> {
        let config = store.load_or_migrate(id_server, key)?;
        Self::from_loaded_config(store, options, runtime, config)
    }

    fn from_loaded_config(
        store: Box<dyn ProfileStore>,
        options: Box<dyn OptionsBackend>,
        runtime: Box<dyn ActiveProfileBackend>,
        config: ServerProfilesConfig,
    ) -> ResultType<Self> {
        config.validate()?;
        let old_options = options.current()?;
        let old_runtime = runtime.current();
        let active = config.active()?;
        let active_options = apply_profile_options(old_options.clone(), active);
        if let Err(error) = options.apply(active_options) {
            let options_rollback = options.apply(old_options);
            let runtime_rollback = runtime.set(&old_runtime);
            return Err(initialization_rollback_error(
                "failed to apply active server profile options",
                error,
                options_rollback,
                runtime_rollback,
            ));
        }
        if let Err(error) = runtime.set(config.active_peer_namespace()?) {
            let options_rollback = options.apply(old_options);
            let runtime_rollback = runtime.set(&old_runtime);
            return Err(initialization_rollback_error(
                "failed to activate server profile runtime",
                error,
                options_rollback,
                runtime_rollback,
            ));
        }
        Self::with_dependencies(store, options, runtime, config)
    }

    fn with_dependencies(
        store: Box<dyn ProfileStore>,
        options: Box<dyn OptionsBackend>,
        runtime: Box<dyn ActiveProfileBackend>,
        config: ServerProfilesConfig,
    ) -> ResultType<Self> {
        config.validate()?;
        Ok(Self {
            store,
            options,
            runtime,
            config,
            health: ManagerHealth::Healthy,
        })
    }

    fn snapshot(&self) -> ServerProfilesConfig {
        self.config.clone()
    }

    fn active_profile_id(&self) -> &str {
        &self.config.active_profile_id
    }

    fn active_peer_namespace(&self) -> ResultType<&str> {
        self.config.active_peer_namespace()
    }

    fn peer_namespace_for(&self, profile_id: &str) -> ResultType<&str> {
        peer_namespace_for_config(&self.config, profile_id)
    }

    fn add(&mut self, name: &str, id_server: &str, key: &str) -> ResultType<ServerProfilesConfig> {
        self.ensure_healthy()?;
        let profile = ServerProfile::try_new(name, id_server, key)?;
        let mut candidate = self.config.clone();
        candidate.add(profile)?;
        self.store
            .save(&candidate)
            .context("failed to save added server profile")?;
        self.config = candidate;
        Ok(self.snapshot())
    }

    fn update(
        &mut self,
        id: &str,
        name: &str,
        id_server: &str,
        key: &str,
    ) -> ResultType<ServerProfilesConfig> {
        self.ensure_healthy()?;
        let mut profile = ServerProfile::try_new(name, id_server, key)?;
        profile.id = id.to_owned();
        profile.validate()?;
        let mut candidate = self.config.clone();
        let updated = candidate.update(profile)?;
        if id == self.config.active_profile_id {
            self.activate_candidate(candidate, &updated)?;
        } else {
            self.store
                .save(&candidate)
                .context("failed to save updated server profile")?;
            self.config = candidate;
        }
        Ok(self.snapshot())
    }

    fn remove(&mut self, id: &str) -> ResultType<ServerProfilesConfig> {
        self.ensure_healthy()?;
        let removed = self
            .config
            .profiles
            .iter()
            .find(|profile| profile.id == id)
            .cloned()
            .ok_or_else(|| anyhow!("server profile does not exist: {id}"))?;
        let updated = self
            .store
            .remove_profile_transaction(&self.config, id)
            .context("failed to remove server profile")?;
        self.config = updated;
        for namespace in std::iter::once(&removed.peer_namespace_id)
            .chain(removed.retired_peer_namespace_ids.iter())
        {
            hbb_common::config::purge_new_stored_peers_for_profile(namespace);
            #[cfg(feature = "flutter")]
            crate::flutter_ffi::purge_stored_peer_events_for_profile(namespace);
        }
        Ok(self.snapshot())
    }

    fn switch(&mut self, id: &str) -> ResultType<ServerProfilesConfig> {
        self.ensure_healthy()?;
        if id == self.config.active_profile_id {
            return Ok(self.snapshot());
        }
        let mut candidate = self.config.clone();
        candidate.set_active(id)?;
        let profile = candidate.active()?.clone();
        self.activate_candidate(candidate, &profile)?;
        Ok(self.snapshot())
    }

    fn activate_candidate(
        &mut self,
        candidate: ServerProfilesConfig,
        profile: &ServerProfile,
    ) -> ResultType<()> {
        let old_config = self.config.clone();
        let old_options = self.options.current()?;
        let old_runtime = self.runtime.current();
        let new_options = apply_profile_options(old_options.clone(), profile);

        self.store
            .save(&candidate)
            .context("failed to save active server profile")?;
        if let Err(apply_error) = self.options.apply(new_options) {
            return Err(self.rollback_activation(
                "failed to apply server profile options",
                apply_error,
                &old_config,
                old_options,
                &old_runtime,
            ));
        }
        if let Err(runtime_error) = self.runtime.set(&profile.peer_namespace_id) {
            return Err(self.rollback_activation(
                "failed to activate server profile runtime",
                runtime_error,
                &old_config,
                old_options,
                &old_runtime,
            ));
        }
        self.config = candidate;
        Ok(())
    }

    fn rollback_activation(
        &mut self,
        context: &str,
        primary: hbb_common::anyhow::Error,
        old_config: &ServerProfilesConfig,
        old_options: HashMap<String, String>,
        old_runtime: &str,
    ) -> hbb_common::anyhow::Error {
        let config_rollback = self.store.save(old_config);
        let options_rollback = self.options.apply(old_options);
        let runtime_rollback = self.runtime.set(old_runtime);
        let mut message = format!("{context}: {primary}");
        let mut degraded = append_rollback_error(&mut message, "config", config_rollback);
        degraded |= append_rollback_error(&mut message, "options", options_rollback);
        degraded |= append_rollback_error(&mut message, "runtime", runtime_rollback);
        if degraded {
            self.health = ManagerHealth::Degraded(
                "server profile state is degraded after incomplete rollback".to_owned(),
            );
        }
        anyhow!(message)
    }

    fn ensure_healthy(&self) -> ResultType<()> {
        match &self.health {
            ManagerHealth::Healthy => Ok(()),
            ManagerHealth::Degraded(error) => Err(anyhow!(error.clone())),
        }
    }

    fn degraded_error(&self) -> Option<&str> {
        match &self.health {
            ManagerHealth::Healthy => None,
            ManagerHealth::Degraded(error) => Some(error),
        }
    }
}

fn initialization_rollback_error(
    context: &str,
    primary: hbb_common::anyhow::Error,
    options_rollback: ResultType<()>,
    runtime_rollback: ResultType<()>,
) -> hbb_common::anyhow::Error {
    let mut message = format!("{context}: {primary}");
    let _ = append_rollback_error(&mut message, "options", options_rollback);
    let _ = append_rollback_error(&mut message, "runtime", runtime_rollback);
    anyhow!(message)
}

fn append_rollback_error(message: &mut String, part: &str, result: ResultType<()>) -> bool {
    if let Err(error) = result {
        message.push_str(&format!("; failed to roll back {part}: {error}"));
        true
    } else {
        false
    }
}

fn set_or_remove(options: &mut HashMap<String, String>, key: &str, value: &str) {
    if value.is_empty() {
        options.remove(key);
    } else {
        options.insert(key.to_owned(), value.to_owned());
    }
}

fn apply_profile_options(
    mut options: HashMap<String, String>,
    profile: &ServerProfile,
) -> HashMap<String, String> {
    set_or_remove(&mut options, RENDEZVOUS_SERVER_OPTION, &profile.id_server);
    set_or_remove(&mut options, KEY_OPTION, &profile.key);
    options.remove(RELAY_SERVER_OPTION);
    options.remove(API_SERVER_OPTION);
    options
}

#[derive(Serialize)]
pub(crate) struct ServerProfileResponse {
    ok: bool,
    error: String,
    config: Option<PublicServerProfilesConfig>,
}

#[derive(Serialize)]
struct PublicServerProfilesConfig {
    version: u32,
    active_profile_id: String,
    profiles: Vec<PublicServerProfile>,
}

#[derive(Serialize)]
struct PublicServerProfile {
    id: String,
    name: String,
    id_server: String,
    key: String,
}

impl From<ServerProfilesConfig> for PublicServerProfilesConfig {
    fn from(config: ServerProfilesConfig) -> Self {
        Self {
            version: config.version,
            active_profile_id: config.active_profile_id,
            profiles: config
                .profiles
                .into_iter()
                .map(|profile| PublicServerProfile {
                    id: profile.id,
                    name: profile.name,
                    id_server: profile.id_server,
                    key: profile.key,
                })
                .collect(),
        }
    }
}

fn response_json(result: ResultType<ServerProfilesConfig>) -> String {
    match result {
        Ok(config) => response_json_parts(true, String::new(), Some(config)),
        Err(error) => response_json_parts(false, error.to_string(), None),
    }
}

fn response_json_parts(ok: bool, error: String, config: Option<ServerProfilesConfig>) -> String {
    let response = ServerProfileResponse {
        ok,
        error,
        config: config.map(PublicServerProfilesConfig::from),
    };
    serde_json::to_string(&response).unwrap_or_else(|_| SERIALIZATION_ERROR_JSON.to_owned())
}

fn with_manager(
    operation: impl FnOnce(&mut ServerProfileManager) -> ResultType<ServerProfilesConfig>,
) -> String {
    let mut state = match MANAGER.lock() {
        Ok(state) => state,
        Err(_) => return response_json(Err(anyhow!("server profile manager lock is poisoned"))),
    };
    let Some(manager) = state.manager.as_mut() else {
        return state.unavailable_response();
    };
    match operation(manager) {
        Ok(config) => response_json_parts(true, String::new(), Some(config)),
        Err(error) => response_json_parts(
            false,
            error.to_string(),
            manager.degraded_error().map(|_| manager.snapshot()),
        ),
    }
}

pub(crate) fn initialize() -> ResultType<ServerProfilesConfig> {
    initialize_or_recover(false)
}

fn initialize_or_recover(recover: bool) -> ResultType<ServerProfilesConfig> {
    let mut state = MANAGER
        .lock()
        .map_err(|_| anyhow!("server profile manager lock is poisoned"))?;
    let store: Box<dyn ProfileStore> = Box::new(ServerProfileStore::production());
    state.ensure_root(&store.identity())?;
    if !recover {
        if let Some(manager) = state.manager.as_ref() {
            if manager.degraded_error().is_none() {
                return Ok(manager.snapshot());
            }
        }
    }

    let options = ProductionOptions;
    let mut key = String::new();
    let result = options.current().and_then(|canonical| {
        let id_server = canonical
            .get(RENDEZVOUS_SERVER_OPTION)
            .cloned()
            .unwrap_or_default();
        key = canonical.get(KEY_OPTION).cloned().unwrap_or_default();
        let config = if recover {
            store.recover_from_options(&id_server, &key)
        } else {
            store.load_or_migrate(&id_server, &key)
        }?;
        ServerProfileManager::from_loaded_config(
            store,
            Box::new(options),
            Box::new(ProductionActiveProfile),
            config,
        )
    });
    state.finish_initialization(result, &key)
}

fn safe_initialization_error(error: &hbb_common::anyhow::Error, key: &str) -> String {
    let mut safe = error.to_string();
    if !key.is_empty() {
        safe = safe.replace(key, "<redacted>");
    }
    safe
}

pub(crate) fn recover() -> String {
    let result = initialize_or_recover(false).or_else(|_| initialize_or_recover(true));
    response_json(result)
}

pub(crate) fn get() -> String {
    with_manager(|manager| {
        manager.ensure_healthy()?;
        Ok(manager.snapshot())
    })
}

pub(crate) fn capture_active_peer_namespace() -> ResultType<String> {
    let state = MANAGER
        .lock()
        .map_err(|_| anyhow!("server profile manager lock is poisoned"))?;
    let manager = state.manager.as_ref().ok_or_else(|| {
        anyhow!(
            "{}",
            state
                .init_error
                .as_deref()
                .unwrap_or("server profile manager is not initialized")
        )
    })?;
    manager.ensure_healthy()?;
    Ok(manager.active_peer_namespace()?.to_owned())
}

pub(crate) fn resolve_peer_namespace(profile_id: &str) -> ResultType<String> {
    let state = MANAGER
        .lock()
        .map_err(|_| anyhow!("server profile manager lock is poisoned"))?;
    let manager = state.manager.as_ref().ok_or_else(|| {
        anyhow!(
            "{}",
            state
                .init_error
                .as_deref()
                .unwrap_or("server profile manager is not initialized")
        )
    })?;
    manager.ensure_healthy()?;
    Ok(manager.peer_namespace_for(profile_id)?.to_owned())
}

pub(crate) fn peer_namespace_for_config<'a>(
    config: &'a ServerProfilesConfig,
    profile_id: &str,
) -> ResultType<&'a str> {
    config
        .profiles
        .iter()
        .find(|profile| profile.id == profile_id)
        .map(|profile| profile.peer_namespace_id.as_str())
        .ok_or_else(|| anyhow!("server profile does not exist: {profile_id}"))
}

pub(crate) fn retired_peer_namespaces() -> ResultType<Vec<String>> {
    let state = MANAGER
        .lock()
        .map_err(|_| anyhow!("server profile manager lock is poisoned"))?;
    let manager = state.manager.as_ref().ok_or_else(|| {
        anyhow!(
            "{}",
            state
                .init_error
                .as_deref()
                .unwrap_or("server profile manager is not initialized")
        )
    })?;
    manager.ensure_healthy()?;
    Ok(manager
        .config
        .profiles
        .iter()
        .flat_map(|profile| profile.retired_peer_namespace_ids.iter().cloned())
        .collect())
}

pub(crate) fn add(name: &str, id_server: &str, key: &str) -> String {
    with_manager(|manager| manager.add(name, id_server, key))
}

pub(crate) fn update(id: &str, name: &str, id_server: &str, key: &str) -> String {
    with_manager(|manager| manager.update(id, name, id_server, key))
}

pub(crate) fn remove(id: &str) -> String {
    with_manager(|manager| manager.remove(id))
}

pub(crate) fn switch(id: &str) -> String {
    with_manager(|manager| manager.switch(id))
}

#[cfg(test)]
mod tests {
    use super::*;
    use hbb_common::config::{
        ServerProfile, ServerProfileStore, ServerProfilesConfig, SERVER_PROFILES_VERSION,
    };
    use std::{
        collections::HashMap,
        fs,
        path::PathBuf,
        sync::{
            atomic::{AtomicUsize, Ordering},
            mpsc, Arc, Condvar, Mutex,
        },
        thread,
        time::Duration,
    };

    struct TempRoot(PathBuf);

    impl TempRoot {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "rustdesk-server-profile-manager-{}",
                hbb_common::uuid::Uuid::new_v4()
            ));
            fs::create_dir_all(&path).expect("temporary root should be created");
            Self(path)
        }
    }

    impl Drop for TempRoot {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[derive(Default)]
    struct Faults {
        fail_save: bool,
    }

    struct TestStore {
        real: ServerProfileStore,
        faults: Arc<Mutex<Faults>>,
    }

    impl ProfileStore for TestStore {
        fn identity(&self) -> PathBuf {
            self.real.root().to_owned()
        }

        fn load_or_migrate(
            &self,
            id_server: &str,
            key: &str,
        ) -> hbb_common::ResultType<ServerProfilesConfig> {
            self.real.load_or_migrate(id_server, key)
        }

        fn recover_from_options(
            &self,
            id_server: &str,
            key: &str,
        ) -> hbb_common::ResultType<ServerProfilesConfig> {
            self.real.recover_from_options(id_server, key)
        }

        fn save(&self, config: &ServerProfilesConfig) -> hbb_common::ResultType<()> {
            if self.faults.lock().expect("fault lock").fail_save {
                return Err(hbb_common::anyhow::anyhow!("injected save failure"));
            }
            self.real.save(config)
        }

        fn remove_profile_transaction(
            &self,
            current: &ServerProfilesConfig,
            id: &str,
        ) -> hbb_common::ResultType<ServerProfilesConfig> {
            let faults = self.faults.lock().expect("fault lock");
            if faults.fail_save {
                return Err(hbb_common::anyhow::anyhow!("injected save failure"));
            }
            drop(faults);
            self.real.remove_profile_transaction(current, id)
        }
    }

    struct TestOptions {
        state: Arc<Mutex<HashMap<String, String>>>,
        calls: Arc<Mutex<usize>>,
        fail_next: Arc<Mutex<bool>>,
    }

    impl OptionsBackend for TestOptions {
        fn current(&self) -> hbb_common::ResultType<HashMap<String, String>> {
            Ok(self.state.lock().expect("options lock").clone())
        }

        fn apply(&self, options: HashMap<String, String>) -> hbb_common::ResultType<()> {
            *self.calls.lock().expect("calls lock") += 1;
            *self.state.lock().expect("options lock") = options;
            let mut fail = self.fail_next.lock().expect("failure lock");
            if *fail {
                *fail = false;
                return Err(hbb_common::anyhow::anyhow!("injected apply failure"));
            }
            Ok(())
        }
    }

    struct TestRuntime(Arc<Mutex<String>>);

    impl ActiveProfileBackend for TestRuntime {
        fn current(&self) -> String {
            self.0.lock().expect("runtime lock").clone()
        }

        fn set(&self, id: &str) -> hbb_common::ResultType<()> {
            *self.0.lock().expect("runtime lock") = id.to_owned();
            Ok(())
        }
    }

    struct RollbackStore {
        real: ServerProfileStore,
        save_calls: AtomicUsize,
        fail_save_call: Option<usize>,
    }

    impl ProfileStore for RollbackStore {
        fn identity(&self) -> PathBuf {
            self.real.root().to_owned()
        }

        fn load_or_migrate(
            &self,
            id_server: &str,
            key: &str,
        ) -> hbb_common::ResultType<ServerProfilesConfig> {
            self.real.load_or_migrate(id_server, key)
        }

        fn recover_from_options(
            &self,
            id_server: &str,
            key: &str,
        ) -> hbb_common::ResultType<ServerProfilesConfig> {
            self.real.recover_from_options(id_server, key)
        }

        fn save(&self, config: &ServerProfilesConfig) -> hbb_common::ResultType<()> {
            let call = self.save_calls.fetch_add(1, Ordering::SeqCst) + 1;
            if self.fail_save_call == Some(call) {
                return Err(anyhow!("injected config rollback failure"));
            }
            self.real.save(config)
        }

        fn remove_profile_transaction(
            &self,
            current: &ServerProfilesConfig,
            id: &str,
        ) -> hbb_common::ResultType<ServerProfilesConfig> {
            self.real.remove_profile_transaction(current, id)
        }
    }

    struct CallFailOptions {
        state: Arc<Mutex<HashMap<String, String>>>,
        calls: AtomicUsize,
        fail_calls: Vec<usize>,
    }

    impl OptionsBackend for CallFailOptions {
        fn current(&self) -> hbb_common::ResultType<HashMap<String, String>> {
            Ok(self.state.lock().expect("options lock").clone())
        }

        fn apply(&self, options: HashMap<String, String>) -> hbb_common::ResultType<()> {
            let call = self.calls.fetch_add(1, Ordering::SeqCst) + 1;
            *self.state.lock().expect("options lock") = options;
            if self.fail_calls.contains(&call) {
                return Err(anyhow!("injected options failure on call {call}"));
            }
            Ok(())
        }
    }

    struct CallFailRuntime {
        state: Arc<Mutex<String>>,
        calls: AtomicUsize,
        fail_calls: Vec<usize>,
    }

    struct RejectCurrentOptions;

    struct BlockingOptions {
        state: Arc<Mutex<HashMap<String, String>>>,
        entered: Mutex<Option<mpsc::Sender<()>>>,
        release: Arc<(Mutex<bool>, Condvar)>,
    }

    impl OptionsBackend for BlockingOptions {
        fn current(&self) -> hbb_common::ResultType<HashMap<String, String>> {
            Ok(self.state.lock().expect("options lock").clone())
        }

        fn apply(&self, options: HashMap<String, String>) -> hbb_common::ResultType<()> {
            *self.state.lock().expect("options lock") = options;
            if let Some(entered) = self.entered.lock().expect("entered lock").take() {
                entered.send(()).expect("signal apply window");
            }
            let (released, condvar) = &*self.release;
            let mut released = released.lock().expect("release lock");
            while !*released {
                released = condvar.wait(released).expect("release wait");
            }
            Ok(())
        }
    }

    impl OptionsBackend for RejectCurrentOptions {
        fn current(&self) -> hbb_common::ResultType<HashMap<String, String>> {
            Err(anyhow!("injected canonical options read failure"))
        }

        fn apply(&self, _options: HashMap<String, String>) -> hbb_common::ResultType<()> {
            panic!("options must not be applied after canonical read failure")
        }
    }

    impl ActiveProfileBackend for CallFailRuntime {
        fn current(&self) -> String {
            self.state.lock().expect("runtime lock").clone()
        }

        fn set(&self, id: &str) -> hbb_common::ResultType<()> {
            let call = self.calls.fetch_add(1, Ordering::SeqCst) + 1;
            *self.state.lock().expect("runtime lock") = id.to_owned();
            if self.fail_calls.contains(&call) {
                return Err(anyhow!("injected runtime failure on call {call}"));
            }
            Ok(())
        }
    }

    fn rollback_manager(
        fail_save_call: Option<usize>,
        option_fail_calls: Vec<usize>,
        runtime_fail_calls: Vec<usize>,
    ) -> (TempRoot, ServerProfileManager) {
        let root = TempRoot::new();
        let store = ServerProfileStore::with_root(&root.0);
        let config = ServerProfilesConfig {
            version: SERVER_PROFILES_VERSION,
            active_profile_id: "home".to_owned(),
            profiles: vec![
                profile("home", "Home", "home.example.com", "home-key"),
                profile("office", "Office", "office.example.com", "office-key"),
            ],
        };
        store.save(&config).expect("config should save");
        let manager = ServerProfileManager::with_dependencies(
            Box::new(RollbackStore {
                real: store,
                save_calls: AtomicUsize::new(0),
                fail_save_call,
            }),
            Box::new(CallFailOptions {
                state: Arc::new(Mutex::new(HashMap::new())),
                calls: AtomicUsize::new(0),
                fail_calls: option_fail_calls,
            }),
            Box::new(CallFailRuntime {
                state: Arc::new(Mutex::new("home".to_owned())),
                calls: AtomicUsize::new(0),
                fail_calls: runtime_fail_calls,
            }),
            config,
        )
        .expect("manager should initialize");
        (root, manager)
    }

    struct Fixture {
        _root: TempRoot,
        store: ServerProfileStore,
        manager: ServerProfileManager,
        faults: Arc<Mutex<Faults>>,
        options: Arc<Mutex<HashMap<String, String>>>,
        calls: Arc<Mutex<usize>>,
        fail_next: Arc<Mutex<bool>>,
        runtime: Arc<Mutex<String>>,
    }

    fn profile(id: &str, name: &str, id_server: &str, key: &str) -> ServerProfile {
        ServerProfile {
            id: id.to_owned(),
            name: name.to_owned(),
            id_server: id_server.to_owned(),
            key: key.to_owned(),
            peer_namespace_id: id.to_owned(),
            retired_peer_namespace_ids: Vec::new(),
        }
    }

    fn fixture() -> Fixture {
        let root = TempRoot::new();
        let store = ServerProfileStore::with_root(&root.0);
        let config = ServerProfilesConfig {
            version: SERVER_PROFILES_VERSION,
            active_profile_id: "home".to_owned(),
            profiles: vec![
                profile("home", "Home", "home.example.com", "home-key"),
                profile("office", "Office", "office.example.com", "office-key"),
            ],
        };
        store.save(&config).expect("fixture config should save");
        let faults = Arc::new(Mutex::new(Faults::default()));
        let options = Arc::new(Mutex::new(HashMap::from([
            (
                "custom-rendezvous-server".to_owned(),
                "home.example.com".to_owned(),
            ),
            ("key".to_owned(), "home-key".to_owned()),
            ("relay-server".to_owned(), "old-relay".to_owned()),
            ("api-server".to_owned(), "old-api".to_owned()),
            ("keep-me".to_owned(), "yes".to_owned()),
        ])));
        let calls = Arc::new(Mutex::new(0));
        let fail_next = Arc::new(Mutex::new(false));
        let runtime = Arc::new(Mutex::new("home".to_owned()));
        let manager = ServerProfileManager::with_dependencies(
            Box::new(TestStore {
                real: store.clone(),
                faults: faults.clone(),
            }),
            Box::new(TestOptions {
                state: options.clone(),
                calls: calls.clone(),
                fail_next: fail_next.clone(),
            }),
            Box::new(TestRuntime(runtime.clone())),
            config,
        )
        .expect("fixture manager should initialize");
        Fixture {
            _root: root,
            store,
            manager,
            faults,
            options,
            calls,
            fail_next,
            runtime,
        }
    }

    #[test]
    fn apply_profile_options_replaces_only_profile_network_fields() {
        let old = HashMap::from([
            ("custom-rendezvous-server".to_owned(), "old".to_owned()),
            ("key".to_owned(), "old-key".to_owned()),
            ("relay-server".to_owned(), "relay".to_owned()),
            ("api-server".to_owned(), "api".to_owned()),
            ("keep-me".to_owned(), "yes".to_owned()),
        ]);
        let changed = apply_profile_options(old, &profile("office", "Office", "new", ""));
        assert_eq!(
            changed.get("custom-rendezvous-server").map(String::as_str),
            Some("new")
        );
        assert!(!changed.contains_key("key"));
        assert!(!changed.contains_key("relay-server"));
        assert!(!changed.contains_key("api-server"));
        assert_eq!(changed.get("keep-me").map(String::as_str), Some("yes"));
    }

    #[test]
    fn add_changes_memory_only_after_successful_save() {
        let mut fixture = fixture();
        fixture.faults.lock().expect("fault lock").fail_save = true;
        assert!(fixture
            .manager
            .add("Lab", "lab.example.com", "secret")
            .is_err());
        assert_eq!(fixture.manager.snapshot().profiles.len(), 2);
        fixture.faults.lock().expect("fault lock").fail_save = false;
        fixture
            .manager
            .add("Lab", "lab.example.com", "secret")
            .expect("add should succeed");
        assert_eq!(fixture.manager.snapshot().profiles.len(), 3);
        assert_eq!(
            fixture.store.load().expect("saved config").profiles.len(),
            3
        );
    }

    #[test]
    fn switch_success_updates_persisted_runtime_and_options_once() {
        let mut fixture = fixture();
        fixture
            .manager
            .switch("office")
            .expect("switch should succeed");
        assert_eq!(fixture.manager.active_profile_id(), "office");
        assert_eq!(
            fixture
                .store
                .load()
                .expect("saved config")
                .active_profile_id,
            "office"
        );
        assert_eq!(&*fixture.runtime.lock().expect("runtime lock"), "office");
        assert_eq!(*fixture.calls.lock().expect("calls lock"), 1);
        let options = fixture.options.lock().expect("options lock");
        assert_eq!(
            options.get("custom-rendezvous-server").map(String::as_str),
            Some("office.example.com")
        );
        assert_eq!(options.get("keep-me").map(String::as_str), Some("yes"));
        assert!(!options.contains_key("relay-server"));
    }

    #[test]
    fn active_identity_update_rotates_runtime_to_the_new_peer_namespace() {
        let mut fixture = fixture();
        let old_namespace = fixture.manager.snapshot().profiles[0]
            .peer_namespace_id
            .clone();

        fixture
            .manager
            .update("home", "Home", "new-home.example.com", "new-key")
            .expect("active identity update should succeed");

        let active = fixture
            .manager
            .snapshot()
            .active()
            .expect("active profile")
            .clone();
        assert_ne!(active.peer_namespace_id, old_namespace);
        assert_eq!(active.retired_peer_namespace_ids, vec![old_namespace]);
        assert_eq!(
            &*fixture.runtime.lock().expect("runtime lock"),
            &active.peer_namespace_id
        );
    }

    #[test]
    fn nonactive_identity_update_does_not_change_active_runtime() {
        let mut fixture = fixture();

        fixture
            .manager
            .update("office", "Office", "new-office.example.com", "new-key")
            .expect("non-active identity update should succeed");

        assert_eq!(&*fixture.runtime.lock().expect("runtime lock"), "home");
    }

    #[test]
    fn active_identity_update_failure_rolls_back_namespace_options_and_runtime() {
        let mut fixture = fixture();
        let old_config = fixture.manager.snapshot();
        let old_options = fixture.options.lock().expect("options lock").clone();
        *fixture.fail_next.lock().expect("failure lock") = true;

        assert!(fixture
            .manager
            .update("home", "Home", "new-home.example.com", "new-key")
            .is_err());

        assert_eq!(fixture.manager.snapshot(), old_config);
        assert_eq!(fixture.store.load().expect("stored config"), old_config);
        assert_eq!(*fixture.options.lock().expect("options lock"), old_options);
        assert_eq!(&*fixture.runtime.lock().expect("runtime lock"), "home");
    }

    #[test]
    fn switch_apply_failure_restores_persisted_runtime_and_options() {
        let mut fixture = fixture();
        let old_options = fixture.options.lock().expect("options lock").clone();
        *fixture.fail_next.lock().expect("failure lock") = true;
        assert!(fixture.manager.switch("office").is_err());
        assert_eq!(fixture.manager.active_profile_id(), "home");
        assert_eq!(
            fixture
                .store
                .load()
                .expect("saved config")
                .active_profile_id,
            "home"
        );
        assert_eq!(&*fixture.runtime.lock().expect("runtime lock"), "home");
        assert_eq!(*fixture.options.lock().expect("options lock"), old_options);
    }

    #[test]
    fn config_rollback_failure_degrades_manager_and_blocks_mutations() {
        let (_root, mut manager) = rollback_manager(Some(2), vec![1], vec![]);
        assert!(manager.switch("office").is_err());
        let error = manager
            .add("Lab", "lab.example.com", "lab-key")
            .expect_err("degraded manager must reject add");
        assert!(error.to_string().contains("degraded"));
    }

    #[test]
    fn canonical_options_read_failure_prevents_persisting_candidate() {
        let root = TempRoot::new();
        let store = ServerProfileStore::with_root(&root.0);
        let config = ServerProfilesConfig {
            version: SERVER_PROFILES_VERSION,
            active_profile_id: "home".to_owned(),
            profiles: vec![
                profile("home", "Home", "home.example.com", "home-key"),
                profile("office", "Office", "office.example.com", "office-key"),
            ],
        };
        store.save(&config).expect("config should save");
        let mut manager = ServerProfileManager::with_dependencies(
            Box::new(ServerProfileStore::with_root(&root.0)),
            Box::new(RejectCurrentOptions),
            Box::new(TestRuntime(Arc::new(Mutex::new("home".to_owned())))),
            config.clone(),
        )
        .expect("manager should initialize");

        assert!(manager.switch("office").is_err());
        assert_eq!(store.load().expect("stored config should load"), config);
        assert_eq!(manager.active_profile_id(), "home");
    }

    #[test]
    fn options_rollback_failure_degrades_manager_and_blocks_mutations() {
        let (_root, mut manager) = rollback_manager(None, vec![1, 2], vec![]);
        assert!(manager.switch("office").is_err());
        let error = manager
            .remove("office")
            .expect_err("degraded manager must reject remove");
        assert!(error.to_string().contains("degraded"));
    }

    #[test]
    fn runtime_rollback_failure_degrades_manager_and_blocks_mutations() {
        let (_root, mut manager) = rollback_manager(None, vec![], vec![1, 2]);
        assert!(manager.switch("office").is_err());
        let error = manager
            .update("office", "Office 2", "office2.example.com", "key2")
            .expect_err("degraded manager must reject update");
        assert!(error.to_string().contains("degraded"));
    }

    #[test]
    fn active_update_applies_immediately_but_inactive_update_does_not() {
        let mut fixture = fixture();
        fixture
            .manager
            .update("office", "Office 2", "office2.example.com", "key2")
            .expect("inactive update");
        assert_eq!(*fixture.calls.lock().expect("calls lock"), 0);
        fixture
            .manager
            .update("home", "Home 2", "home2.example.com", "key3")
            .expect("active update");
        assert_eq!(*fixture.calls.lock().expect("calls lock"), 1);
        assert_eq!(
            fixture
                .options
                .lock()
                .expect("options lock")
                .get("custom-rendezvous-server")
                .map(String::as_str),
            Some("home2.example.com")
        );
    }

    #[test]
    fn delete_uses_real_atomic_store_and_removes_config_and_profile() {
        let mut fixture = fixture();
        let peer_root = fixture
            .store
            .profile_peer_root("office")
            .expect("profile root");
        fs::create_dir_all(peer_root.join("peers")).expect("peer root");
        fixture
            .manager
            .remove("office")
            .expect("atomic deletion should succeed");

        assert!(!peer_root.exists());
        assert!(!fixture
            .store
            .load()
            .expect("saved config")
            .profiles
            .iter()
            .any(|p| p.id == "office"));
        assert!(!fixture
            .manager
            .snapshot()
            .profiles
            .iter()
            .any(|p| p.id == "office"));
    }

    #[test]
    fn error_response_does_not_include_submitted_key() {
        let mut fixture = fixture();
        fixture.faults.lock().expect("fault lock").fail_save = true;
        let json = response_json(fixture.manager.add("Lab", "lab.example.com", "do-not-leak"));
        assert!(!json.contains("do-not-leak"));
        assert!(json.contains("\"ok\":false"));
    }

    #[test]
    fn successful_response_does_not_expose_internal_peer_namespaces() {
        let mut config = ServerProfilesConfig::default_with("server.example.com", "key");
        config.profiles[0].peer_namespace_id = "internal-current".to_owned();
        config.profiles[0].retired_peer_namespace_ids = vec!["internal-retired".to_owned()];

        let response = response_json(Ok(config));

        assert!(!response.contains("peer_namespace"));
        assert!(!response.contains("internal-current"));
        assert!(!response.contains("internal-retired"));
    }

    #[test]
    fn manager_resolves_current_namespace_from_logical_profile_id() {
        let mut fixture = fixture();
        fixture.manager.config.profiles[0].peer_namespace_id = "current-space".to_owned();
        fixture.manager.config.profiles[0].retired_peer_namespace_ids =
            vec!["retired-space".to_owned()];

        assert_eq!(
            fixture.manager.peer_namespace_for("home").unwrap(),
            "current-space"
        );
        assert!(fixture.manager.peer_namespace_for("missing").is_err());
    }

    #[test]
    fn initialization_keeps_existing_profiles_and_activates_persisted_profile() {
        let root = TempRoot::new();
        let store = ServerProfileStore::with_root(&root.0);
        let config = ServerProfilesConfig {
            version: SERVER_PROFILES_VERSION,
            active_profile_id: "office".to_owned(),
            profiles: vec![
                profile("home", "Home", "home.example.com", "home-key"),
                profile("office", "Office", "office.example.com", "office-key"),
            ],
        };
        store.save(&config).expect("existing config should save");
        let runtime = Arc::new(Mutex::new("home".to_owned()));
        let options = Arc::new(Mutex::new(HashMap::from([(
            "keep-me".to_owned(),
            "yes".to_owned(),
        )])));
        let calls = Arc::new(Mutex::new(0));
        let manager = ServerProfileManager::initialize_with_dependencies(
            Box::new(TestStore {
                real: store,
                faults: Arc::new(Mutex::new(Faults::default())),
            }),
            Box::new(TestOptions {
                state: options.clone(),
                calls: calls.clone(),
                fail_next: Arc::new(Mutex::new(false)),
            }),
            Box::new(TestRuntime(runtime.clone())),
            "stale.example.com",
            "stale-key",
        )
        .expect("manager should initialize");

        assert_eq!(manager.snapshot(), config);
        assert_eq!(&*runtime.lock().expect("runtime lock"), "office");
        assert_eq!(*calls.lock().expect("calls lock"), 1);
        let options = options.lock().expect("options lock");
        assert_eq!(
            options.get("custom-rendezvous-server").map(String::as_str),
            Some("office.example.com")
        );
        assert_eq!(options.get("key").map(String::as_str), Some("office-key"));
        assert_eq!(options.get("keep-me").map(String::as_str), Some("yes"));
    }

    #[test]
    fn manager_state_accepts_same_root_and_rejects_different_root() {
        let (_manager_root, manager) = rollback_manager(None, vec![], vec![]);
        let mut state = ManagerState::default();
        let first = PathBuf::from("/tmp/profile-root-one");
        state
            .ensure_root(&first)
            .expect("first root should be accepted");
        state
            .ensure_root(&first)
            .expect("same root should be idempotent");
        state.manager = Some(manager);
        let error = state
            .ensure_root(&PathBuf::from("/tmp/profile-root-two"))
            .expect_err("different root must be rejected");
        assert!(error.to_string().contains("different configuration root"));
        assert!(state.manager.is_none(), "old-root manager must be disabled");
    }

    #[test]
    fn unavailable_response_returns_saved_safe_initialization_error() {
        let state = ManagerState {
            root: Some(PathBuf::from("/tmp/profile-root")),
            manager: None,
            init_error: Some("server profiles config is corrupt".to_owned()),
        };
        let json = state.unavailable_response();
        assert!(json.contains("server profiles config is corrupt"));
        assert!(json.contains("\"ok\":false"));
    }

    #[test]
    fn active_profile_capture_waits_for_switch_transaction_to_finish() {
        let root = TempRoot::new();
        let store = ServerProfileStore::with_root(&root.0);
        let config = ServerProfilesConfig {
            version: SERVER_PROFILES_VERSION,
            active_profile_id: "home".to_owned(),
            profiles: vec![
                profile("home", "Home", "home.example.com", "home-key"),
                profile("office", "Office", "office.example.com", "office-key"),
            ],
        };
        store.save(&config).expect("config save");
        let (entered_tx, entered_rx) = mpsc::channel();
        let release = Arc::new((Mutex::new(false), Condvar::new()));
        let manager = ServerProfileManager::with_dependencies(
            Box::new(store),
            Box::new(BlockingOptions {
                state: Arc::new(Mutex::new(HashMap::new())),
                entered: Mutex::new(Some(entered_tx)),
                release: release.clone(),
            }),
            Box::new(TestRuntime(Arc::new(Mutex::new("home".to_owned())))),
            config,
        )
        .expect("manager initialize");
        {
            let mut state = MANAGER.lock().expect("manager lock");
            *state = ManagerState {
                root: Some(root.0.clone()),
                manager: Some(manager),
                init_error: None,
            };
        }

        let switch_thread = thread::spawn(|| switch("office"));
        entered_rx
            .recv_timeout(Duration::from_secs(2))
            .expect("switch enters options apply");
        let (capture_tx, capture_rx) = mpsc::channel();
        let (capture_entered_tx, capture_entered_rx) = mpsc::channel();
        let capture_thread = thread::spawn(move || {
            capture_entered_tx
                .send(())
                .expect("signal capture invocation");
            capture_tx
                .send(capture_active_peer_namespace())
                .expect("send capture result");
        });
        capture_entered_rx
            .recv_timeout(Duration::from_secs(2))
            .expect("capture thread starts invocation");
        assert!(capture_rx.recv_timeout(Duration::from_millis(50)).is_err());

        let (released, condvar) = &*release;
        *released.lock().expect("release lock") = true;
        condvar.notify_all();
        assert!(switch_thread
            .join()
            .expect("switch thread")
            .contains("\"ok\":true"));
        assert_eq!(
            capture_rx
                .recv_timeout(Duration::from_secs(2))
                .expect("capture completes")
                .expect("capture succeeds"),
            "office"
        );
        capture_thread.join().expect("capture thread");
        *MANAGER.lock().expect("manager lock") = ManagerState::default();
    }

    #[test]
    fn snapshot_reader_does_not_hold_manager_lock_during_io() {
        let fixture = fixture();
        *MANAGER.lock().expect("manager lock") = ManagerState {
            root: Some(fixture._root.0.clone()),
            manager: Some(fixture.manager),
            init_error: None,
        };
        struct ResetManager;
        impl Drop for ResetManager {
            fn drop(&mut self) {
                *MANAGER.lock().expect("manager lock") = ManagerState::default();
            }
        }
        let _reset = ResetManager;
        let (reader_started_tx, reader_started_rx) = mpsc::channel();
        let (release_reader_tx, release_reader_rx) = mpsc::channel();
        let reader = thread::spawn(move || {
            let namespace = resolve_peer_namespace("home").expect("resolve namespace");
            reader_started_tx
                .send(namespace)
                .expect("signal blocked reader");
            release_reader_rx.recv().expect("release reader");
        });

        assert_eq!(
            reader_started_rx
                .recv_timeout(Duration::from_secs(2))
                .expect("reader starts"),
            "home"
        );
        {
            let mut state = MANAGER
                .try_lock()
                .expect("reader must not hold manager lock");
            state
                .manager
                .as_mut()
                .expect("manager exists")
                .switch("office")
                .expect("switch while reader is blocked");
        }
        release_reader_tx.send(()).expect("release reader");
        reader.join().expect("reader thread");
    }

    #[test]
    fn canonical_options_initialization_error_is_saved_for_ffi_responses() {
        let mut state = ManagerState::default();
        let options = RejectCurrentOptions;
        let result = options.current().and_then(|_| {
            Err::<ServerProfileManager, _>(anyhow!("unexpected initialization continuation"))
        });

        assert!(state.finish_initialization(result, "").is_err());
        let json = state.unavailable_response();
        assert!(json.contains("injected canonical options read failure"));
        assert!(!json.contains("manager is not initialized"));
    }
}
