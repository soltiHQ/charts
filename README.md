# charts

Helm charts for solti.

| Chart | What it deploys |
| -- | -- |
| [podium](charts/podium/README.md) | podium, the solti control plane, as one standalone node with its state on a persistent volume. |

```sh
helm install podium ./charts/podium -n podium --create-namespace --set secrets.existingSecret=podium-secrets
```

Each chart's README lists what it needs before the install.
