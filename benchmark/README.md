# rjq benchmarks

Run:

```sh
ruby benchmark/jq_compare.rb
```

Set `ITERATIONS=50` for a longer run. If `jq` is available on `PATH`, the script prints an rjq-vs-jq Markdown table and verifies stdout equality for each scenario. Without `jq`, it reports rjq timings only.
