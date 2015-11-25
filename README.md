# Dredd-bench — HTTP API Benchmarking tool

- Install

```
$ npm install -g dredd-bench
```


- Run benchmark

```
$ dredd-bench ./blueprint.md http://localhost:3000 --latency=50 --time=5000 --concurrency=4 --method=GET
```
