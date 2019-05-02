FROM erlang:alpine

RUN mkdir -p /buildroot/rebar3/bin
ADD https://s3.amazonaws.com/rebar3/rebar3 /buildroot/rebar3/bin/rebar3
RUN chmod a+x /buildroot/rebar3/bin/rebar3

ENV PATH=/buildroot/rebar3/bin:$PATH

WORKDIR /buildroot

COPY . broen

WORKDIR broen
RUN rebar3 as prod release

FROM alpine

RUN apk add --no-cache openssl && \
    apk add --no-cache ncurses-libs

COPY --from=0 /buildroot/broen/_build/prod/rel/broen /broen

# Expose relevant ports
EXPOSE 8080
EXPOSE 8443

CMD ["/broen/bin/broen", "foreground"]