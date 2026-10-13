using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
  services = [
    ( name = "rv",
      worker = (
        modules = [
          ( name = "worker.js", esModule = embed "worker.js" ),
        ],
        compatibilityDate = "2025-09-01",
      )
    ),
  ],
  sockets = [
    ( name = "http", address = "127.0.0.1:8787", http = (), service = "rv" ),
  ],
);
