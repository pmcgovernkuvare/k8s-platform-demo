FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download || true
COPY . .
RUN go mod tidy && CGO_ENABLED=0 go build -o /order-service .

FROM gcr.io/distroless/static-debian12
COPY --from=build /order-service /order-service
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/order-service"]
