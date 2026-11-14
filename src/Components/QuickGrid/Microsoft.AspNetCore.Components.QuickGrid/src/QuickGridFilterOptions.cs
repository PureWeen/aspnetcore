// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

namespace Microsoft.AspNetCore.Components.QuickGrid;

/// <summary>
/// Configures column filtering behavior for a <see cref="QuickGrid{TGridItem}"/>.
/// </summary>
public class QuickGridFilterOptions
{
    /// <summary>
    /// Gets or sets the debounce delay in milliseconds before applying column filter input.
    /// </summary>
    public int DebounceMilliseconds { get; set; } = 250;

    /// <summary>
    /// Gets or sets the initial filter values keyed by column title.
    /// </summary>
    public Dictionary<string, string> DefaultColumnFilters { get; set; }
}

/// <summary>
/// Represents a column filter change notification.
/// </summary>
public readonly record struct QuickGridFilterChangedContext(string ColumnTitle, string? FilterValue);

/// <summary>
/// Handles asynchronous filter changes for a <see cref="QuickGrid{TGridItem}"/>.
/// </summary>
public interface IQuickGridFilterHandler
{
    /// <summary>
    /// Applies the specified column filter change asynchronously.
    /// </summary>
    Task ApplyFilterAsync(QuickGridFilterChangedContext context);
}
