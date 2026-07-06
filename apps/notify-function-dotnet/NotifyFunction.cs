using System.Diagnostics;
using System.Diagnostics.Metrics;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace NotifyFunctionApp;

// Shape of the message queue-bridge (apps/queue-bridge-python) writes to
// Azurite. traceId/spanId are how we re-attach this async hop to the same
// Tempo trace as the synchronous edge-api -> order-service call that
// triggered it - see StartLinkedActivity below.
public record OrderNotification(
    [property: JsonPropertyName("orderId")] string OrderId,
    [property: JsonPropertyName("item")] string Item,
    [property: JsonPropertyName("quantity")] int Quantity,
    [property: JsonPropertyName("enqueuedAt")] string EnqueuedAt,
    [property: JsonPropertyName("traceId")] string TraceId,
    [property: JsonPropertyName("spanId")] string SpanId
);

public class NotifyFunction
{
    public const string ActivitySourceName = "NotifyFunction";
    public const string MeterName = "NotifyFunction";

    private static readonly ActivitySource ActivitySourceInstance = new(ActivitySourceName);
    private static readonly Meter MeterInstance = new(MeterName);
    private static readonly Counter<long> NotificationsProcessed =
        MeterInstance.CreateCounter<long>("notifications_processed_total");
    private static readonly Counter<long> NotificationsFailed =
        MeterInstance.CreateCounter<long>("notifications_failed_total");

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    private readonly ILogger<NotifyFunction> _logger;

    public NotifyFunction(ILogger<NotifyFunction> logger)
    {
        _logger = logger;
    }

    // KEDA scales the Deployment running this function from 0 to N pods
    // based on the depth of the "order-notifications" queue in Azurite
    // (see gitops/infra-values/keda/notify-function-scaledobject.yaml).
    // Each pod's Functions host polls the queue independently - this
    // single [Function] method is all the "autoscaling logic" the code
    // needs; KEDA + the Storage Queue trigger binding handle the rest.
    [Function("ProcessOrderNotification")]
    public void Run(
        [QueueTrigger("%NOTIFICATIONS_QUEUE_NAME%", Connection = "AzureWebJobsStorage")] string queueMessage)
    {
        OrderNotification? notification;
        try
        {
            notification = JsonSerializer.Deserialize<OrderNotification>(queueMessage, JsonOptions);
        }
        catch (JsonException ex)
        {
            NotificationsFailed.Add(1);
            _logger.LogError(ex, "failed to parse queue message: {Message}", queueMessage);
            return;
        }

        if (notification is null)
        {
            NotificationsFailed.Add(1);
            _logger.LogWarning("received empty/unparseable notification message");
            return;
        }

        using var activity = StartLinkedActivity(notification);

        // Simulated "send the customer a notification" side effect. A real
        // implementation would call an email/SMS provider here.
        _logger.LogInformation(
            "notification sent for order {OrderId} ({Quantity}x {Item}) trace_id={TraceId}",
            notification.OrderId, notification.Quantity, notification.Item, notification.TraceId);

        NotificationsProcessed.Add(1);
    }

    private static Activity? StartLinkedActivity(OrderNotification notification)
    {
        if (string.IsNullOrEmpty(notification.TraceId) || string.IsNullOrEmpty(notification.SpanId))
        {
            return ActivitySourceInstance.StartActivity("process-order-notification", ActivityKind.Consumer);
        }

        try
        {
            var traceId = ActivityTraceId.CreateFromString(notification.TraceId);
            var spanId = ActivitySpanId.CreateFromString(notification.SpanId);
            var parentContext = new ActivityContext(traceId, spanId, ActivityTraceFlags.Recorded);
            return ActivitySourceInstance.StartActivity(
                "process-order-notification", ActivityKind.Consumer, parentContext);
        }
        catch (ArgumentOutOfRangeException)
        {
            // Malformed trace/span id (e.g. queue-bridge had no active span) -
            // fall back to starting a fresh, unlinked trace rather than crashing.
            return ActivitySourceInstance.StartActivity("process-order-notification", ActivityKind.Consumer);
        }
    }
}
