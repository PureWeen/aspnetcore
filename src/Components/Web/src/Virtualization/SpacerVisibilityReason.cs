// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

namespace Microsoft.AspNetCore.Components.Web.Virtualization;

// Numeric values cross the JS/.NET boundary and must stay synchronized with Virtualize.ts.
internal enum SpacerVisibilityReason
{
    UserScroll = 0,

    ProgrammaticScroll = 1,

    ViewportFill = 2,

    RenderedContentMeasurement = 3,
}
