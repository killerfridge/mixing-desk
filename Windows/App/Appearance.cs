using System;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Media;
using Microsoft.Win32;
namespace MixingDesk;

sealed class Preferences
{
    public string Appearance { get; set; } = "System";
    public string Density { get; set; } = "Automatic";
    public string Bank { get; set; } = "All";
    static string FilePath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Mixing Desk", "appearance.json");
    public static Preferences Current { get; } = Load();
    static Preferences Load()
    {
        try
        {
            return JsonSerializer.Deserialize<Preferences>(File.ReadAllText(FilePath)) ?? new();
        }
        catch { return new(); }
    }
    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this));
        }
        catch (Exception e) { StartupLog.Write("Could not save appearance", e); }
    }
}
static class Theme
{
    public static Brush Background { get; private set; } = Brushes.Black;
    public static Brush Panel { get; private set; } = Brushes.Black;
    public static Brush Recessed { get; private set; } = Brushes.Black;
    public static Brush Text { get; private set; } = Brushes.White;
    public static Brush Muted { get; private set; } = Brushes.Gray;
    public static Brush Accent { get; private set; } = Brushes.Orange;
    public static Brush Line { get; private set; } = Brushes.Gray;
    public static bool Dark
    {
        get; private set;
    }
    static Brush Hex(string value) => (Brush)new BrushConverter().ConvertFromString(value)!;
    public static Brush Color(string name) => name switch
    {
        "amber" => Accent,
        "purple" => Hex(Dark ? "#AB8FF2" : "#7552B8"),
        "blue" => Hex(Dark ? "#61A6F0" : "#286EB8"),
        "rose" => Hex(Dark ? "#F75991" : "#B92F65"),
        "output" => Hex(Dark ? "#32C5E8" : "#087D95"),
        _ => Hex(Dark ? "#4DCCB0" : "#197F6B")
    };
    public static void Apply()
    {
        bool systemDark = false;
        try
        {
            systemDark = (int?)Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1) == 0;
        }
        catch { }
        Dark = Preferences.Current.Appearance == "Dark" || (Preferences.Current.Appearance == "System" && systemDark);
        Background = Hex(Dark ? "#0E1113" : "#F2F4F5");
        Panel = Hex(Dark ? "#181C1F" : "#FFFFFF");
        Recessed = Hex(Dark ? "#121517" : "#E9EDF0");
        Text = Hex(Dark ? "#E9EBED" : "#182027");
        Muted = Hex(Dark ? "#9BA3A9" : "#5C6872");
        Accent = Hex(Dark ? "#F7A84D" : "#9F570E");
        Line = Hex(Dark ? "#32383D" : "#D1D8DD");
        foreach (var (key, value) in new[] { ("Background", Background), ("Panel", Panel), ("Recessed", Recessed), ("Text", Text), ("Muted", Muted), ("Accent", Accent), ("Line", Line) })
            Application.Current.Resources["Desk." + key] = value;
    }
    public static void Bind(FrameworkElement element, DependencyProperty property, Brush brush)
    {
        string? key = ReferenceEquals(brush, Text) ? "Text" : ReferenceEquals(brush, Muted) ? "Muted" : ReferenceEquals(brush, Accent) ? "Accent" : ReferenceEquals(brush, Panel) ? "Panel" : ReferenceEquals(brush, Background) ? "Background" : ReferenceEquals(brush, Line) ? "Line" : ReferenceEquals(brush, Recessed) ? "Recessed" : null;
        if (key is null)
            element.SetValue(property, brush);
        else
            element.SetResourceReference(property, "Desk." + key);
    }
    public static void InstallStyles(Application app)
    {
        var styles = (ResourceDictionary)XamlReader.Parse("""
        <ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
          <Style TargetType="Button">
            <Setter Property="Foreground" Value="{DynamicResource Desk.Text}"/><Setter Property="Background" Value="{DynamicResource Desk.Panel}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource Desk.Line}"/><Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,6"/><Setter Property="Margin" Value="3"/><Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
              <Border x:Name="Border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center" RecognizesAccessKey="True"/></Border>
              <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource Desk.Accent}"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource Desk.Accent}"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger></ControlTemplate.Triggers>
            </ControlTemplate></Setter.Value></Setter>
          </Style>
          <Style TargetType="TextBox"><Setter Property="Foreground" Value="{DynamicResource Desk.Text}"/><Setter Property="Background" Value="{DynamicResource Desk.Recessed}"/><Setter Property="BorderBrush" Value="{DynamicResource Desk.Line}"/><Setter Property="CaretBrush" Value="{DynamicResource Desk.Text}"/><Setter Property="Padding" Value="5"/><Setter Property="Margin" Value="3"/></Style>
          <Style TargetType="Menu"><Setter Property="Foreground" Value="{DynamicResource Desk.Text}"/><Setter Property="Background" Value="{DynamicResource Desk.Panel}"/></Style>
          <Style TargetType="MenuItem"><Setter Property="Foreground" Value="{DynamicResource Desk.Text}"/><Setter Property="Background" Value="{DynamicResource Desk.Panel}"/></Style>
          <Style TargetType="ContextMenu"><Setter Property="Foreground" Value="{DynamicResource Desk.Text}"/><Setter Property="Background" Value="{DynamicResource Desk.Panel}"/></Style>
          <Style TargetType="ComboBox"><Setter Property="Foreground" Value="Black"/><Setter Property="Background" Value="WhiteSmoke"/><Setter Property="Padding" Value="6,3"/></Style>
          <Style TargetType="ComboBoxItem"><Setter Property="Foreground" Value="Black"/><Setter Property="Background" Value="WhiteSmoke"/></Style>
          <Style TargetType="TabItem"><Setter Property="Foreground" Value="{DynamicResource Desk.Muted}"/><Setter Property="Padding" Value="16,9"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TabItem"><Border x:Name="Tab" Background="Transparent" CornerRadius="6" Padding="{TemplateBinding Padding}" Margin="2"><ContentPresenter ContentSource="Header"/></Border><ControlTemplate.Triggers><Trigger Property="IsSelected" Value="True"><Setter Property="Foreground" Value="{DynamicResource Desk.Accent}"/><Setter TargetName="Tab" Property="Background" Value="{DynamicResource Desk.Panel}"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Tab" Property="BorderBrush" Value="{DynamicResource Desk.Accent}"/><Setter TargetName="Tab" Property="BorderThickness" Value="1"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
          <Style TargetType="TabControl"><Setter Property="Background" Value="Transparent"/><Setter Property="BorderThickness" Value="0"/></Style>
        </ResourceDictionary>
        """);
        foreach (var key in styles.Keys)
            app.Resources[key] = styles[key];
    }
}
