# The image-check fixture. `build` writes the CLI and the runtime stages copy it
# in. The last stage, `runtime`, runs as a non-root user and is what a caller
# gets by default. `runtime-root` is the same image without the USER line;
# self-test builds it under allow-root: true.
FROM alpine:3.23 AS build
ARG FIXTURE_VERSION=dev
COPY cli.sh /src/cli.sh
RUN install -D -m 0755 /src/cli.sh /out/fixture-cli \
    && sed -i "s/@VERSION@/${FIXTURE_VERSION}/" /out/fixture-cli

FROM alpine:3.23 AS runtime-root
COPY --from=build /out/fixture-cli /usr/local/bin/fixture-cli
ENTRYPOINT ["fixture-cli"]

FROM runtime-root AS runtime
RUN adduser -D -u 10001 app
USER app
