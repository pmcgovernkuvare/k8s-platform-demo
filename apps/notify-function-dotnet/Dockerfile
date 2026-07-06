# Microsoft only publishes the Azure Functions base images for linux/amd64
# (no arm64 manifest - see
# https://github.com/Azure/azure-functions-docker/issues/740). On Apple
# Silicon, Docker's default native-platform resolution then fails with
# "no match for platform in manifest: not found". Pinning --platform on both
# stages forces amd64 + emulation (Rosetta on Docker Desktop for Mac), which
# works identically on Intel and Apple Silicon - just slower to build/run
# than a native image would be, which is fine for a demo.
FROM --platform=linux/amd64 mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY NotifyFunction.csproj ./
RUN dotnet restore
# NotifyFunction.csproj declares local.settings.json.example as a <None
# CopyToOutputDirectory> item, so `dotnet publish` fails with MSB3030
# ("could not copy the file") unless it's present in the build context too -
# it's a checked-in placeholder (well-known public Azurite emulator
# credentials, not a real secret) that only `func start` actually reads;
# the containerized host ignores it and gets its config from env vars set
# by the Kubernetes Deployment, so shipping it is harmless.
COPY Program.cs NotifyFunction.cs host.json local.settings.json.example ./
RUN dotnet publish -c Release -o /app/publish

FROM --platform=linux/amd64 mcr.microsoft.com/azure-functions/dotnet-isolated:4-dotnet-isolated8.0
ENV AzureFunctionsJobHost__Logging__Console__IsEnabled=true \
    ASPNETCORE_URLS=http://+:80
COPY --from=build /app/publish /home/site/wwwroot