using System.Text.Json;
using NotifyFunctionApp;
using Xunit;

namespace NotifyFunctionApp.Tests;

// These exercise the message-parsing contract between queue-bridge (Python)
// and this function - the part most likely to silently drift if either
// side changes field names/casing. Run locally with `dotnet test` (a .NET 8
// SDK is required; not available in the environment that generated this
// repo, so this file has not been compiled/executed - please run it as
// part of your first local setup).
public class OrderNotificationTests
{
    private static readonly JsonSerializerOptions Options = new() { PropertyNameCaseInsensitive = true };

    [Fact]
    public void Deserializes_QueueBridge_Payload_Shape()
    {
        const string json = """
        {"orderId":"ord-42","item":"widget","quantity":3,"enqueuedAt":"2026-07-02T00:00:00Z","traceId":"0af7651916cd43dd8448eb211c80319c","spanId":"b7ad6b7169203331"}
        """;

        var result = JsonSerializer.Deserialize<OrderNotification>(json, Options);

        Assert.NotNull(result);
        Assert.Equal("ord-42", result!.OrderId);
        Assert.Equal("widget", result.Item);
        Assert.Equal(3, result.Quantity);
        Assert.Equal("0af7651916cd43dd8448eb211c80319c", result.TraceId);
        Assert.Equal("b7ad6b7169203331", result.SpanId);
    }

    [Fact]
    public void Handles_Missing_Trace_Fields_Gracefully()
    {
        const string json = """{"orderId":"ord-1","item":"gizmo","quantity":1,"enqueuedAt":"","traceId":"","spanId":""}""";

        var result = JsonSerializer.Deserialize<OrderNotification>(json, Options);

        Assert.NotNull(result);
        Assert.Equal(string.Empty, result!.TraceId);
    }
}
