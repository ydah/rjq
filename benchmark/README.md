# rjq benchmarks

Run:

```sh
bundle exec ruby benchmark/jq_compare.rb
```

Set `ITERATIONS=50` for a longer run. The script reports median and p95 process-level latency. If `jq` is available on `PATH`, it fails on any stdout mismatch before reporting the jq comparison. Without `jq`, it reports rjq timings only.
