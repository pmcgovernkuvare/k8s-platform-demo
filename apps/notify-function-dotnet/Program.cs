using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using OpenTelemetry.Metrics;

// Isolated-worker bootstrap: this process runs standalone (that's what
// makes it container-friendly) and talks to the Azure Functions host over
// gRPC. ConfigureFunctionsWorkerDefaults() wires up the trigger/binding
// pipeline; everything below it is just standard .NET generic-host
// dependency injection, same as any other .NET service in the platform.
var host = new HostBuilder()
    .ConfigureFunctionsWorkerDefaults()
    .ConfigureServices(services =>
    {
        var otlpEndpoint = Environment.GetEnvironmentVariable("OTEL_EXPORTER_OTLP_ENDPOINT")
            ?? "http://otel-collector.platform-observability.svc.cluster.local:4317";
        var serviceName = Environment.GetEnvironmentVariable("OTEL_SERVICE_NAME") ?? "notify-function";

        services.AddOpenTelemetry()
            .ConfigureResource(r => r.AddService(serviceName))
            .WithTracing(tracing => tracing
                .AddSource(NotifyFunctionApp.NotifyFunction.ActivitySourceName)
                .AddOtlpExporter(o => o.Endpoint = new Uri(otlpEndpoint)))
            .WithMetrics(metrics => metrics
                .AddMeter(NotifyFunctionApp.NotifyFunction.MeterName)
                .AddOtlpExporter(o => o.Endpoint = new Uri(otlpEndpoint)));
    })
    .Build();

host.Run();
