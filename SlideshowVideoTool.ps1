[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $script:AppRoot 'SlideshowEngine.psm1') -Force
Import-Module (Join-Path $script:AppRoot 'SlideshowAnalysis.psm1') -Force
Import-Module (Join-Path $script:AppRoot 'SlideshowUpdate.psm1') -Force

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class CreatorFlowWindowTheme {
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int valueSize);
}

// The folder picker in .NET Framework's WinForms is still the old
// SHBrowseForFolder tree: a cramped list with no address bar, no search, no
// pinned places, and none of the navigation of the file dialogs it sits
// beside in this window. Windows has shipped a better one since Vista - the
// same IFileOpenDialog used for files, put into folder-picking mode - and
// that is what File Explorer itself opens. Declaring the three shell
// interfaces here is the whole cost of using it from PowerShell.
public static class CreatorFlowFolderPicker {
    private const uint FOS_PICKFOLDERS     = 0x00000020;
    private const uint FOS_FORCEFILESYSTEM = 0x00000040;
    private const uint FOS_PATHMUSTEXIST   = 0x00000800;
    private const uint SIGDN_FILESYSPATH   = 0x80058000;
    private const int  ERROR_CANCELLED     = unchecked((int)0x800704C7);
    private const string IID_IShellItem    = "43826d1e-e718-42ee-bc55-a1e261c37bfe";

    [ComImport, Guid(IID_IShellItem), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, [MarshalAs(UnmanagedType.LPWStr)] out string ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }

    // Every method of IModalWindow and IFileDialog has to be declared, in
    // order, even though only a few are called: the runtime builds the call
    // by vtable slot, so a missing entry silently invokes the wrong function.
    [ComImport, Guid("d57c7288-d4ad-4768-be02-9d969532d960"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileOpenDialog {
        [PreserveSig] int Show(IntPtr parent);
        void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
        void SetFileTypeIndex(uint iFileType);
        void GetFileTypeIndex(out uint piFileType);
        void Advise(IntPtr pfde, out uint pdwCookie);
        void Unadvise(uint dwCookie);
        void SetOptions(uint fos);
        void GetOptions(out uint pfos);
        void SetDefaultFolder(IShellItem psi);
        void SetFolder(IShellItem psi);
        void GetFolder(out IShellItem ppsi);
        void GetCurrentSelection(out IShellItem ppsi);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string pszName);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
        void GetResult(out IShellItem ppsi);
        void AddPlace(IShellItem psi, int fdap);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string pszDefaultExtension);
        void Close(int hr);
        void SetClientGuid(ref Guid guid);
        void ClearClientData();
        void SetFilter(IntPtr pFilter);
        void GetResults(out IntPtr ppenum);
        void GetSelectedItems(out IntPtr ppsai);
    }

    [ComImport, Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
    private class FileOpenDialog { }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    private static extern void SHCreateItemFromParsingName(
        [MarshalAs(UnmanagedType.LPWStr)] string path, IntPtr bindingContext,
        [MarshalAs(UnmanagedType.LPStruct)] Guid interfaceId,
        [MarshalAs(UnmanagedType.Interface)] out IShellItem item);

    // The dialog is opened from the UI thread, so the thread's active window
    // is the one it should sit in front of. Passing zero lets it open behind.
    [DllImport("user32.dll")]
    private static extern IntPtr GetActiveWindow();

    // Returns the chosen folder, or null when the person closes the dialog.
    public static string Show(string title, string initialPath) {
        IFileOpenDialog dialog = (IFileOpenDialog)new FileOpenDialog();
        try {
            uint options;
            dialog.GetOptions(out options);
            dialog.SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST);
            if (!string.IsNullOrEmpty(title)) { dialog.SetTitle(title); }

            if (!string.IsNullOrEmpty(initialPath) && System.IO.Directory.Exists(initialPath)) {
                IShellItem start;
                SHCreateItemFromParsingName(initialPath, IntPtr.Zero, new Guid(IID_IShellItem), out start);
                try { dialog.SetFolder(start); }
                finally { Marshal.ReleaseComObject(start); }
            }

            int hr = dialog.Show(GetActiveWindow());
            if (hr == ERROR_CANCELLED) { return null; }
            if (hr != 0) { Marshal.ThrowExceptionForHR(hr); }

            IShellItem chosen;
            dialog.GetResult(out chosen);
            try {
                string path;
                chosen.GetDisplayName(SIGDN_FILESYSPATH, out path);
                return path;
            }
            finally { Marshal.ReleaseComObject(chosen); }
        }
        finally { Marshal.ReleaseComObject(dialog); }
    }
}
'@

$script:DataRoot = Join-Path $env:LOCALAPPDATA 'SlideshowVideoTool'
# Bumping this invalidates resume directories. Segments rendered by an older
# pipeline must not be concatenated with segments from a newer one, because the
# camera motion would visibly change partway through the video.
# Bumped because motion effects moved back onto the processor. Any segment
# already on disk may have come from the Vulkan graph, which did not reproduce
# itself, so resuming onto it could splice a mis-timed stretch into the middle
# of an otherwise correct video.
$script:RenderPipelineVersion = 'cpu-motion-effects-v15-reproducible'
$script:SettingsPath = Join-Path $script:DataRoot 'settings.json'
$script:PreviewPath = Join-Path $script:DataRoot 'preview.mp4'
$script:LastErrorPath = Join-Path $script:DataRoot 'last-error.log'
$script:DiagnosticLogPath = Join-Path $script:DataRoot 'tool-diagnostic.log'
# The render worker re-encodes the voiceover to AAC whatever container it
# arrives in, so the tool accepts the usual voiceover formats rather than M4A
# alone. Folders prepared per channel normally hold MP3s.
$script:VoiceoverExtensions = @('.m4a', '.mp3', '.wav', '.aac', '.flac', '.ogg', '.opus')
$script:VoiceoverFilter = 'Voiceover audio (*.m4a;*.mp3;*.wav;*.aac;*.flac;*.ogg;*.opus)|*.m4a;*.mp3;*.wav;*.aac;*.flac;*.ogg;*.opus|All files (*.*)|*.*'
# Remembered so tomorrow's scan of the same channels folder is one click.
$script:LastChannelsRoot = ''
New-Item -ItemType Directory -Path $script:DataRoot -Force | Out-Null

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="CreatorFlow" Width="1360" Height="820" MinWidth="1120" MinHeight="680" WindowState="Maximized"
        WindowStartupLocation="CenterScreen" Background="#17171A" Foreground="#E9E9E6"
        FontFamily="Segoe UI" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
    <Window.Resources>
        <!-- Every grey here is hue-neutral on purpose. This window sits beside
             the picture being judged, and a blue or warm cast in the chrome
             shifts how the photograph beside it reads. The only saturated
             colour in the interface is tungsten, and it is spent on three
             things only: the active step, the primary action, and the caption
             currently being edited. -->
        <SolidColorBrush x:Key="GroundBrush" Color="#17171A"/>
        <SolidColorBrush x:Key="PanelBrush" Color="#1E1E22"/>
        <SolidColorBrush x:Key="RaisedBrush" Color="#26262B"/>
        <SolidColorBrush x:Key="SunkenBrush" Color="#101012"/>
        <SolidColorBrush x:Key="LineBrush" Color="#33333A"/>
        <SolidColorBrush x:Key="StrongLineBrush" Color="#41414A"/>
        <SolidColorBrush x:Key="TextBrush" Color="#E9E9E6"/>
        <SolidColorBrush x:Key="DimBrush" Color="#A3A39E"/>
        <SolidColorBrush x:Key="MutedBrush" Color="#7E7E7A"/>
        <SolidColorBrush x:Key="AccentBrush" Color="#E0913F"/>
        <SolidColorBrush x:Key="AccentDeepBrush" Color="#8A5424"/>
        <SolidColorBrush x:Key="AccentTintBrush" Color="#2A2119"/>
        <SolidColorBrush x:Key="OkBrush" Color="#7CA97C"/>
        <SolidColorBrush x:Key="BadBrush" Color="#C87068"/>

        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>

        <Style TargetType="Button">
            <Setter Property="Background" Value="{StaticResource RaisedBrush}"/>
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource LineBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="13,7"/>
            <Setter Property="Margin" Value="3"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="SnapsToDevicePixels" Value="True"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.84"/></Trigger>
                            <Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.64"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.55"/></Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="ButtonBorder" Property="BorderBrush" Value="{StaticResource AccentBrush}"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- One workflow step. The badge, label and summary are named so the
             code can show each step's own state without rebuilding the rail. -->
        <Style x:Key="StepButtonStyle" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="Padding" Value="9,8"/>
            <Setter Property="Margin" Value="8,1"/>
        </Style>

        <Style x:Key="ToolButtonStyle" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="Foreground" Value="{StaticResource MutedBrush}"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="Padding" Value="9,6"/>
            <Setter Property="Margin" Value="8,1"/>
            <Setter Property="FontSize" Value="12.5"/>
        </Style>

        <Style x:Key="PrimaryButtonStyle" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="{StaticResource AccentBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
            <Setter Property="Foreground" Value="#1C1206"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="16,7"/>
            <Style.Triggers>
                <!-- Tungsten is bright enough that dimming alone still reads as
                     a button waiting to be pressed. When it cannot be pressed
                     it gives up the accent entirely. -->
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Background" Value="{StaticResource RaisedBrush}"/>
                    <Setter Property="BorderBrush" Value="{StaticResource LineBrush}"/>
                    <Setter Property="Foreground" Value="{StaticResource MutedBrush}"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="QuietButtonStyle" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderBrush" Value="{StaticResource LineBrush}"/>
            <Setter Property="Foreground" Value="{StaticResource DimBrush}"/>
        </Style>

        <Style x:Key="DangerButtonStyle" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderBrush" Value="#5A3A38"/>
            <Setter Property="Foreground" Value="{StaticResource BadBrush}"/>
        </Style>

        <Style x:Key="TabButtonStyle" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="Foreground" Value="{StaticResource MutedBrush}"/>
            <Setter Property="Margin" Value="0"/>
            <Setter Property="Padding" Value="0,6"/>
            <Setter Property="FontSize" Value="11.5"/>
        </Style>

        <!-- The Batch / Single video switch in the title bar. The code paints
             the chosen half, the same way it paints the active caption tab. -->
        <Style x:Key="ModeButtonStyle" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="Foreground" Value="{StaticResource DimBrush}"/>
            <Setter Property="Margin" Value="0"/>
            <Setter Property="Padding" Value="14,5"/>
        </Style>

        <!-- Column headings of the queue table. -->
        <Style x:Key="ColumnHeadText" TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource MutedBrush}"/>
            <Setter Property="FontSize" Value="10.5"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>

        <Style TargetType="TextBox">
            <Setter Property="Background" Value="{StaticResource SunkenBrush}"/>
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="CaretBrush" Value="{StaticResource AccentBrush}"/>
            <Setter Property="SelectionBrush" Value="{StaticResource AccentDeepBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource LineBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="Margin" Value="0"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border x:Name="TextBoxBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4">
                            <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="TextBoxBorder" Property="BorderBrush" Value="{StaticResource AccentBrush}"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- The stock dark-on-dark ComboBox was unreadable. This template owns
             both the closed field and the popup so neither can inherit a
             system colour that does not belong in a dark window. -->
        <Style TargetType="ComboBoxItem">
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Padding" Value="9,6"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBoxItem">
                        <Border x:Name="ItemBorder" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
                            <ContentPresenter/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="ItemBorder" Property="Background" Value="{StaticResource AccentTintBrush}"/></Trigger>
                            <Trigger Property="IsSelected" Value="True"><Setter TargetName="ItemBorder" Property="Background" Value="{StaticResource RaisedBrush}"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="{StaticResource SunkenBrush}"/>
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource LineBrush}"/>
            <Setter Property="Margin" Value="0"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <ToggleButton x:Name="ToggleHost" Focusable="False" ClickMode="Press"
                                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton">
                                        <Border x:Name="FieldBorder" Background="{StaticResource SunkenBrush}" BorderBrush="{StaticResource LineBrush}"
                                                BorderThickness="1" CornerRadius="4">
                                            <Grid>
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="22"/></Grid.ColumnDefinitions>
                                                <Path Grid.Column="1" HorizontalAlignment="Center" VerticalAlignment="Center"
                                                      Data="M0,0 L8,0 L4,5 Z" Fill="#8E8E8A"/>
                                            </Grid>
                                        </Border>
                                        <ControlTemplate.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="FieldBorder" Property="BorderBrush" Value="{StaticResource StrongLineBrush}"/></Trigger>
                                        </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <ContentPresenter Content="{TemplateBinding SelectionBoxItem}" IsHitTestVisible="False"
                                              Margin="10,0,26,0" VerticalAlignment="Center" TextElement.Foreground="{StaticResource TextBrush}"/>
                            <Popup x:Name="PART_Popup" Placement="Bottom" AllowsTransparency="True" Focusable="False"
                                   IsOpen="{TemplateBinding IsDropDownOpen}" PopupAnimation="Fade">
                                <Border Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource StrongLineBrush}" BorderThickness="1"
                                        CornerRadius="4" MinWidth="{TemplateBinding ActualWidth}" MaxHeight="320" Margin="0,3,0,0">
                                    <ScrollViewer><ItemsPresenter/></ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{StaticResource DimBrush}"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="Margin" Value="0,4"/>
            <Setter Property="Cursor" Value="Hand"/>
        </Style>

        <Style TargetType="Slider">
            <Setter Property="Margin" Value="0"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="IsMoveToPointEnabled" Value="True"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Slider">
                        <Grid Height="20" Background="Transparent">
                            <Border Height="3" CornerRadius="2" Background="{StaticResource StrongLineBrush}" VerticalAlignment="Center"/>
                            <Track x:Name="PART_Track">
                                <Track.DecreaseRepeatButton>
                                    <RepeatButton Command="Slider.DecreaseLarge" Focusable="False">
                                        <RepeatButton.Template>
                                            <ControlTemplate TargetType="RepeatButton">
                                                <Border Height="3" CornerRadius="2" Background="{StaticResource AccentBrush}" VerticalAlignment="Center"/>
                                            </ControlTemplate>
                                        </RepeatButton.Template>
                                    </RepeatButton>
                                </Track.DecreaseRepeatButton>
                                <Track.IncreaseRepeatButton>
                                    <RepeatButton Command="Slider.IncreaseLarge" Focusable="False">
                                        <RepeatButton.Template>
                                            <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
                                        </RepeatButton.Template>
                                    </RepeatButton>
                                </Track.IncreaseRepeatButton>
                                <Track.Thumb>
                                    <Thumb Width="12" Height="12">
                                        <Thumb.Template>
                                            <ControlTemplate TargetType="Thumb">
                                                <Ellipse Fill="{StaticResource TextBrush}" Stroke="#0E0E10" StrokeThickness="1"/>
                                            </ControlTemplate>
                                        </Thumb.Template>
                                    </Thumb>
                                </Track.Thumb>
                            </Track>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="ProgressBar">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ProgressBar">
                        <Border Background="{StaticResource StrongLineBrush}" CornerRadius="3" Height="5">
                            <Grid HorizontalAlignment="Left" x:Name="PART_Track">
                                <Border x:Name="PART_Indicator" Background="{StaticResource AccentBrush}" CornerRadius="3" HorizontalAlignment="Left"/>
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="LabelText" TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource MutedBrush}"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="Margin" Value="0,0,0,5"/>
        </Style>
        <Style x:Key="RowLabel" TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource DimBrush}"/>
            <Setter Property="FontSize" Value="12.5"/>
        </Style>
        <Style x:Key="ValueText" TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource DimBrush}"/>
            <Setter Property="FontFamily" Value="Consolas"/>
            <Setter Property="FontSize" Value="11.5"/>
            <Setter Property="HorizontalAlignment" Value="Right"/>
        </Style>
        <Style x:Key="NoteText" TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource MutedBrush}"/>
            <Setter Property="FontSize" Value="11.5"/>
            <Setter Property="TextWrapping" Value="Wrap"/>
            <Setter Property="VerticalAlignment" Value="Top"/>
        </Style>
    </Window.Resources>

    <Grid x:Name="RootGrid">
        <Grid.RowDefinitions>
            <RowDefinition Height="50"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="66"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
            <ColumnDefinition x:Name="NavigationColumn" Width="230"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition x:Name="SettingsColumn" Width="320"/>
        </Grid.ColumnDefinitions>

        <!-- TITLE BAR -->
        <Border Grid.Row="0" Grid.ColumnSpan="3" Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="0,0,0,1">
            <Grid Margin="14,0">
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <!-- Source is set in code so the artwork stays a file on
                         disk rather than being pasted into the layout. -->
                    <Image x:Name="AppLogoImage" Width="24" Height="24" Margin="0,0,10,0"
                           RenderOptions.BitmapScalingMode="HighQuality" SnapsToDevicePixels="True"/>
                    <TextBlock Text="CreatorFlow" FontSize="13.5" FontWeight="SemiBold"/>
                    <TextBlock Text="/" Foreground="#41414A" Margin="9,0"/>
                    <TextBlock x:Name="AppSubtitleText" Text="Slideshow automation studio" Foreground="{StaticResource DimBrush}" FontSize="12.5"/>
                </StackPanel>
                <!-- Most days are a batch of thirty or more videos, so the window
                     opens on the queue. A single video is the other half of the
                     same switch rather than a separate window. -->
                <Border Grid.Column="1" Margin="28,0,0,0" VerticalAlignment="Center" Background="{StaticResource SunkenBrush}"
                        BorderBrush="{StaticResource LineBrush}" BorderThickness="1" CornerRadius="7" Padding="3">
                    <StackPanel Orientation="Horizontal">
                        <Button x:Name="ModeBatchButton" Style="{StaticResource ModeButtonStyle}">
                            <StackPanel Orientation="Horizontal">
                                <TextBlock x:Name="ModeBatchLabel" Text="Batch" FontSize="12.5"/>
                                <Border Background="{StaticResource SunkenBrush}" CornerRadius="8" Padding="7,0" Margin="7,0,0,0" Height="17">
                                    <TextBlock x:Name="BatchCountText" Text="0" FontSize="10.5" Foreground="{StaticResource DimBrush}"/>
                                </Border>
                            </StackPanel>
                        </Button>
                        <Button x:Name="ModeSingleButton" Style="{StaticResource ModeButtonStyle}" Margin="2,0,0,0">
                            <TextBlock x:Name="ModeSingleLabel" Text="Single video" FontSize="12.5"/>
                        </Button>
                    </StackPanel>
                </Border>
                <StackPanel Grid.Column="3" Orientation="Horizontal" VerticalAlignment="Center">
                    <Border Background="{StaticResource RaisedBrush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="1" CornerRadius="13" Padding="10,0" Height="26" Margin="3">
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                            <Ellipse Width="6" Height="6" Fill="{StaticResource OkBrush}" Margin="0,0,7,0"/>
                            <TextBlock x:Name="EncoderText" Text="Checking GPU..." Foreground="{StaticResource DimBrush}" FontSize="11.5"/>
                        </StackPanel>
                    </Border>
                    <Button x:Name="OpenProjectButton" Content="Open" Style="{StaticResource QuietButtonStyle}"/>
                    <Button x:Name="SaveProjectButton" Content="Save" Style="{StaticResource QuietButtonStyle}"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- WORKFLOW RAIL -->
        <Border x:Name="NavigationPanel" Grid.Row="1" Grid.Column="0" Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="0,0,1,0">
            <Grid>
                <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

                <ScrollViewer VerticalScrollBarVisibility="Auto">
                <Grid>
                <!-- Batch: the channels in the queue, then the settings every
                     video in it shares. Each video's own files live in the
                     inspector on the right, beside the queue. -->
                <StackPanel x:Name="BatchRailPanel">
                    <TextBlock Text="CHANNELS" Foreground="{StaticResource MutedBrush}" FontSize="10" FontWeight="Bold" Margin="17,15,0,9"/>
                    <StackPanel x:Name="ChannelFilterPanel"/>
                    <Border Height="1" Background="{StaticResource LineBrush}" Margin="17,12"/>
                    <TextBlock Text="APPLIES TO EVERY VIDEO" Foreground="{StaticResource MutedBrush}" FontSize="10" FontWeight="Bold" Margin="17,2,0,7"/>
                    <Button x:Name="BatchNavMotionButton" Style="{StaticResource StepButtonStyle}">
                        <StackPanel>
                            <TextBlock Text="Motion" FontSize="13"/>
                            <TextBlock x:Name="BatchNavMotionSummaryText" Text="5-7s holds, 110% zoom" Foreground="{StaticResource MutedBrush}" FontSize="11" TextTrimming="CharacterEllipsis"/>
                        </StackPanel>
                    </Button>
                    <Button x:Name="BatchNavCaptionsButton" Style="{StaticResource StepButtonStyle}">
                        <StackPanel>
                            <TextBlock Text="Captions" FontSize="13"/>
                            <TextBlock x:Name="BatchNavCaptionsSummaryText" Text="Off" Foreground="{StaticResource MutedBrush}" FontSize="11" TextTrimming="CharacterEllipsis"/>
                        </StackPanel>
                    </Button>
                    <Button x:Name="BatchNavBlankingButton" Style="{StaticResource StepButtonStyle}">
                        <StackPanel>
                            <TextBlock Text="Backdrop" FontSize="13"/>
                            <TextBlock x:Name="BatchNavBlankingSummaryText" Text="Blur 40, 65% bright" Foreground="{StaticResource MutedBrush}" FontSize="11" TextTrimming="CharacterEllipsis"/>
                        </StackPanel>
                    </Button>
                    <Button x:Name="BatchNavExportButton" Style="{StaticResource StepButtonStyle}">
                        <StackPanel>
                            <TextBlock Text="Export" FontSize="13"/>
                            <TextBlock x:Name="BatchNavExportSummaryText" Text="YouTube quality" Foreground="{StaticResource MutedBrush}" FontSize="11" TextTrimming="CharacterEllipsis"/>
                        </StackPanel>
                    </Button>
                </StackPanel>

                <StackPanel x:Name="SingleRailPanel" Visibility="Collapsed">
                    <TextBlock Text="WORKFLOW" Foreground="{StaticResource MutedBrush}" FontSize="10" FontWeight="Bold" Margin="17,15,0,9"/>
                    <!-- The five steps are numbered because they genuinely are a
                         sequence: there is nothing to caption before a voiceover
                         is chosen, and nothing to export before either. -->
                    <Button x:Name="NavMediaButton" Style="{StaticResource StepButtonStyle}">
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="26"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                            <Border x:Name="NavMediaBadge" Grid.RowSpan="2" Width="20" Height="20" CornerRadius="10" VerticalAlignment="Top" Margin="0,1,0,0"
                                    Background="Transparent" BorderBrush="{StaticResource StrongLineBrush}" BorderThickness="1">
                                <TextBlock x:Name="NavMediaBadgeText" Text="1" FontSize="10.5" FontWeight="SemiBold" Foreground="{StaticResource MutedBrush}" HorizontalAlignment="Center"/>
                            </Border>
                            <TextBlock Grid.Column="1" Text="Source" FontSize="13"/>
                            <TextBlock x:Name="NavMediaSummaryText" Grid.Column="1" Grid.Row="1" Text="Nothing chosen yet" Foreground="{StaticResource MutedBrush}" FontSize="11" TextTrimming="CharacterEllipsis"/>
                        </Grid>
                    </Button>
                    <Button x:Name="NavMotionButton" Style="{StaticResource StepButtonStyle}">
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="26"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                            <Border x:Name="NavMotionBadge" Grid.RowSpan="2" Width="20" Height="20" CornerRadius="10" VerticalAlignment="Top" Margin="0,1,0,0"
                                    Background="Transparent" BorderBrush="{StaticResource StrongLineBrush}" BorderThickness="1">
                                <TextBlock x:Name="NavMotionBadgeText" Text="2" FontSize="10.5" FontWeight="SemiBold" Foreground="{StaticResource MutedBrush}" HorizontalAlignment="Center"/>
                            </Border>
                            <TextBlock Grid.Column="1" Text="Motion" FontSize="13"/>
                            <TextBlock x:Name="NavMotionSummaryText" Grid.Column="1" Grid.Row="1" Text="5-7s holds, 110% zoom" Foreground="{StaticResource MutedBrush}" FontSize="11" TextTrimming="CharacterEllipsis"/>
                        </Grid>
                    </Button>
                    <Button x:Name="NavCaptionsButton" Style="{StaticResource StepButtonStyle}">
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="26"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                            <Border x:Name="NavCaptionsBadge" Grid.RowSpan="2" Width="20" Height="20" CornerRadius="10" VerticalAlignment="Top" Margin="0,1,0,0"
                                    Background="Transparent" BorderBrush="{StaticResource StrongLineBrush}" BorderThickness="1">
                                <TextBlock x:Name="NavCaptionsBadgeText" Text="3" FontSize="10.5" FontWeight="SemiBold" Foreground="{StaticResource MutedBrush}" HorizontalAlignment="Center"/>
                            </Border>
                            <TextBlock Grid.Column="1" Text="Captions" FontSize="13"/>
                            <TextBlock x:Name="NavCaptionsSummaryText" Grid.Column="1" Grid.Row="1" Text="Not generated" Foreground="{StaticResource MutedBrush}" FontSize="11" TextTrimming="CharacterEllipsis"/>
                        </Grid>
                    </Button>
                    <Button x:Name="NavBlankingButton" Style="{StaticResource StepButtonStyle}">
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="26"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                            <Border x:Name="NavBlankingBadge" Grid.RowSpan="2" Width="20" Height="20" CornerRadius="10" VerticalAlignment="Top" Margin="0,1,0,0"
                                    Background="Transparent" BorderBrush="{StaticResource StrongLineBrush}" BorderThickness="1">
                                <TextBlock x:Name="NavBlankingBadgeText" Text="4" FontSize="10.5" FontWeight="SemiBold" Foreground="{StaticResource MutedBrush}" HorizontalAlignment="Center"/>
                            </Border>
                            <TextBlock Grid.Column="1" Text="Backdrop" FontSize="13"/>
                            <TextBlock x:Name="NavBlankingSummaryText" Grid.Column="1" Grid.Row="1" Text="Blur 40, 65% bright" Foreground="{StaticResource MutedBrush}" FontSize="11" TextTrimming="CharacterEllipsis"/>
                        </Grid>
                    </Button>
                    <Button x:Name="NavExportButton" Style="{StaticResource StepButtonStyle}">
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="26"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                            <Border x:Name="NavExportBadge" Grid.RowSpan="2" Width="20" Height="20" CornerRadius="10" VerticalAlignment="Top" Margin="0,1,0,0"
                                    Background="Transparent" BorderBrush="{StaticResource StrongLineBrush}" BorderThickness="1">
                                <TextBlock x:Name="NavExportBadgeText" Text="5" FontSize="10.5" FontWeight="SemiBold" Foreground="{StaticResource MutedBrush}" HorizontalAlignment="Center"/>
                            </Border>
                            <TextBlock Grid.Column="1" Text="Export" FontSize="13"/>
                            <TextBlock x:Name="NavExportSummaryText" Grid.Column="1" Grid.Row="1" Text="No destination chosen" Foreground="{StaticResource MutedBrush}" FontSize="11" TextTrimming="CharacterEllipsis"/>
                        </Grid>
                    </Button>
                </StackPanel>
                </Grid>
                </ScrollViewer>

                <StackPanel Grid.Row="1">
                    <Border Height="1" Background="{StaticResource LineBrush}" Margin="17,10"/>
                    <Button x:Name="RenderHistoryButton" Style="{StaticResource ToolButtonStyle}">
                        <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                            <TextBlock Text="Render history" Foreground="{StaticResource MutedBrush}" FontSize="12.5"/>
                            <Border x:Name="HistoryCountBadge" Grid.Column="1" Background="{StaticResource RaisedBrush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="1"
                                    CornerRadius="9" Padding="7,0" Height="17" Visibility="Collapsed">
                                <TextBlock x:Name="HistoryCountText" Text="0" FontSize="10" Foreground="{StaticResource DimBrush}"/>
                            </Border>
                        </Grid>
                    </Button>
                    <Button x:Name="CheckUpdatesButton" Style="{StaticResource ToolButtonStyle}" Content="Check for updates"/>
                </StackPanel>

                <StackPanel Grid.Row="2" Margin="11,8,11,12">
                    <Border Background="{StaticResource SunkenBrush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="1" CornerRadius="5" Padding="11,9">
                        <StackPanel>
                            <TextBlock Text="OUTPUT" Foreground="{StaticResource MutedBrush}" FontSize="10" FontWeight="Bold"/>
                            <TextBlock Text="1920x1080  24 fps  H.264" Foreground="{StaticResource DimBrush}" FontFamily="Consolas" FontSize="11.5" Margin="0,4,0,0"/>
                        </StackPanel>
                    </Border>
                </StackPanel>
            </Grid>
        </Border>

        <!-- BATCH STAGE -->
        <!-- The queue is the main page. It used to be a dialog that vanished
             once Render All was pressed, while the window behind it held a
             black player that a batch never used. -->
        <Grid x:Name="BatchView" Grid.Row="1" Grid.Column="1" Margin="20,16,20,14">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel VerticalAlignment="Bottom" Margin="0,0,12,0">
                    <TextBlock x:Name="BatchHeadingText" Text="Today's queue" FontSize="20" FontWeight="SemiBold"/>
                    <TextBlock x:Name="BatchSubheadingText" Text="Scan your channels folder to queue the day's videos." Foreground="{StaticResource DimBrush}" FontSize="12" Margin="0,3,0,0" TextTrimming="CharacterEllipsis"/>
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Bottom">
                    <StackPanel x:Name="QueueActionsPanel" Orientation="Horizontal">
                        <Button x:Name="ScanChannelsButton" Content="Scan channels folder" Background="{StaticResource AccentTintBrush}" BorderBrush="{StaticResource AccentDeepBrush}"
                                ToolTip="Pick the folder that holds your channel folders. Every numbered image folder with a voiceover of the same name is queued, with its own channel's watermark. A titles.txt beside the channel folders names the videos too - see the README for its layout."/>
                        <Button x:Name="AddVideoButton" Content="+ Add video" ToolTip="Pick one video's image folder. A voiceover with the same name beside it is found automatically."/>
                        <Button x:Name="SavedProjectsButton" Content="Saved projects" Style="{StaticResource QuietButtonStyle}" ToolTip="Render project files (.svp.json) saved from Single video."/>
                        <Button x:Name="ClearFinishedButton" Content="Clear finished" Style="{StaticResource QuietButtonStyle}" Visibility="Collapsed"/>
                    </StackPanel>
                    <Button x:Name="ShowQueueButton" Content="Back to the queue" Style="{StaticResource QuietButtonStyle}" Visibility="Collapsed"/>
                </StackPanel>
            </Grid>

            <StackPanel Grid.Row="1" Margin="0,14,0,0">
                <Grid x:Name="DefaultWatermarkRow" Margin="0,0,0,10">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock Text="Watermark for videos added by hand" Foreground="{StaticResource DimBrush}" FontSize="12" Margin="0,0,10,0"
                               ToolTip="Only a starting value. Adding a video copies it into that video's own watermark, which you can change in the panel on the right. A scanned video takes the watermark from its own channel folder instead."/>
                    <TextBox x:Name="BatchWatermarkText" Grid.Column="1"/>
                    <Button x:Name="BrowseBatchWatermarkButton" Grid.Column="2" Content="Browse" Style="{StaticResource QuietButtonStyle}" Margin="6,0,0,0"/>
                </Grid>
                <Border x:Name="ScanSummaryBorder" Visibility="Collapsed" Background="{StaticResource AccentTintBrush}" BorderBrush="#5A3A1C" BorderThickness="1" CornerRadius="6" Padding="12,8" Margin="0,0,0,10">
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBlock x:Name="ScanSummaryText" Text="" FontSize="12.5" TextWrapping="Wrap"/>
                        <Button x:Name="ScanSkippedButton" Grid.Column="1" Content="Skipped - why?" Style="{StaticResource QuietButtonStyle}" Foreground="{StaticResource AccentBrush}"
                                BorderBrush="{StaticResource AccentDeepBrush}" Padding="10,4" Margin="10,0,0,0" Visibility="Collapsed"/>
                    </Grid>
                </Border>
            </StackPanel>

            <Border Grid.Row="2" Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="1" CornerRadius="7">
                <Grid>
                    <!-- THE QUEUE -->
                    <Grid x:Name="QueueTableHost">
                        <Grid.RowDefinitions><RowDefinition Height="34"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                        <Border BorderBrush="{StaticResource LineBrush}" BorderThickness="0,0,0,1" Padding="12,0">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="30"/><ColumnDefinition Width="66"/><ColumnDefinition Width="*"/><ColumnDefinition Width="140"/>
                                    <ColumnDefinition Width="64"/><ColumnDefinition Width="68"/><ColumnDefinition Width="142"/><ColumnDefinition Width="70"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Text="#" Style="{StaticResource ColumnHeadText}"/>
                                <TextBlock Grid.Column="2" Text="VIDEO NAME" Style="{StaticResource ColumnHeadText}"/>
                                <TextBlock Grid.Column="3" Text="CHANNEL" Style="{StaticResource ColumnHeadText}" Margin="10,0,0,0"/>
                                <TextBlock Grid.Column="4" Text="IMAGES" Style="{StaticResource ColumnHeadText}"/>
                                <TextBlock Grid.Column="5" Text="LENGTH" Style="{StaticResource ColumnHeadText}"/>
                                <TextBlock Grid.Column="6" Text="STATUS" Style="{StaticResource ColumnHeadText}"/>
                            </Grid>
                        </Border>
                        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                            <StackPanel x:Name="QueueRowsPanel"/>
                        </ScrollViewer>
                        <StackPanel x:Name="QueueEmptyPanel" Grid.Row="1" HorizontalAlignment="Center" VerticalAlignment="Center" MaxWidth="420">
                            <TextBlock Text="No videos in the queue yet" FontSize="16" FontWeight="SemiBold" HorizontalAlignment="Center"/>
                            <TextBlock Text="Scan your channels folder to queue a whole day at once, or add one video by hand." Foreground="{StaticResource DimBrush}"
                                       FontSize="12.5" TextWrapping="Wrap" TextAlignment="Center" Margin="0,6,0,14"/>
                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                                <Button x:Name="EmptyScanButton" Content="Scan channels folder" Style="{StaticResource PrimaryButtonStyle}"/>
                                <Button x:Name="EmptyAddButton" Content="+ Add video" Style="{StaticResource QuietButtonStyle}"/>
                            </StackPanel>
                        </StackPanel>
                    </Grid>

                    <!-- THE BATCH WHILE IT RENDERS -->
                    <Grid x:Name="RenderTableHost" Visibility="Collapsed">
                        <Grid.RowDefinitions><RowDefinition Height="34"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                        <Border BorderBrush="{StaticResource LineBrush}" BorderThickness="0,0,0,1" Padding="12,0">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="30"/><ColumnDefinition Width="*"/><ColumnDefinition Width="140"/>
                                    <ColumnDefinition Width="68"/><ColumnDefinition Width="210"/><ColumnDefinition Width="82"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Text="#" Style="{StaticResource ColumnHeadText}"/>
                                <TextBlock Grid.Column="1" Text="VIDEO" Style="{StaticResource ColumnHeadText}"/>
                                <TextBlock Grid.Column="2" Text="CHANNEL" Style="{StaticResource ColumnHeadText}" Margin="10,0,0,0"/>
                                <TextBlock Grid.Column="3" Text="LENGTH" Style="{StaticResource ColumnHeadText}"/>
                                <TextBlock Grid.Column="4" Text="STATUS" Style="{StaticResource ColumnHeadText}"/>
                            </Grid>
                        </Border>
                        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                            <StackPanel x:Name="RenderRowsPanel"/>
                        </ScrollViewer>
                    </Grid>
                </Grid>
            </Border>
        </Grid>

        <!-- SINGLE VIDEO STAGE -->
        <Grid x:Name="SingleView" Grid.Row="1" Grid.Column="1" Visibility="Collapsed">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <!-- Shown while a video from the queue is open here for its preview. -->
            <Border x:Name="QueuePreviewBanner" Visibility="Collapsed" Background="{StaticResource AccentTintBrush}" BorderBrush="#5A3A1C" BorderThickness="1"
                    CornerRadius="6" Padding="12,7" Margin="14,14,14,0">
                <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock x:Name="QueuePreviewBannerText" Text="" FontSize="12.5" TextWrapping="Wrap"/>
                    <Button x:Name="BackToQueueButton" Grid.Column="1" Content="Back to the queue" Style="{StaticResource QuietButtonStyle}" Padding="10,4" Margin="10,0,0,0"/>
                </Grid>
            </Border>
            <Grid Grid.Row="1">
        <Grid x:Name="PlayerPanel" Margin="14">
            <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="140"/></Grid.RowDefinitions>

            <Border Grid.Row="0" Background="#0A0A0C" BorderBrush="{StaticResource LineBrush}" BorderThickness="1" CornerRadius="6">
                <Grid ClipToBounds="True">
                    <MediaElement x:Name="PreviewMedia" LoadedBehavior="Manual" UnloadedBehavior="Stop" Stretch="Uniform" ScrubbingEnabled="True" Volume="0.8"/>
                    <Canvas x:Name="CaptionOverlayCanvas" Background="Transparent" ClipToBounds="True">
                        <Border x:Name="LiveCaptionBorder" Visibility="Collapsed" CornerRadius="4" Padding="12,7" Background="#00000000">
                            <Grid>
                                <TextBlock x:Name="LiveCaptionText" Text="Live caption preview" TextWrapping="Wrap" TextAlignment="Center" Foreground="White" FontFamily="Segoe UI Semibold" FontWeight="SemiBold"/>
                                <Thumb x:Name="CaptionMoveThumb" Background="Transparent" Cursor="SizeAll" ToolTip="Drag to reposition captions">
                                    <Thumb.Template>
                                        <!-- The stock Windows Thumb template paints an opaque white
                                             button even when Background is Transparent. -->
                                        <ControlTemplate TargetType="Thumb">
                                            <Border Background="Transparent"/>
                                        </ControlTemplate>
                                    </Thumb.Template>
                                </Thumb>
                                <Thumb x:Name="CaptionResizeThumb" Width="15" Height="15" HorizontalAlignment="Right" VerticalAlignment="Bottom" Cursor="SizeNWSE"
                                       Background="#E0913F" BorderBrush="White" BorderThickness="1" ToolTip="Drag to resize captions">
                                    <Thumb.Template>
                                        <ControlTemplate TargetType="Thumb">
                                            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"/>
                                        </ControlTemplate>
                                    </Thumb.Template>
                                </Thumb>
                            </Grid>
                        </Border>
                    </Canvas>

                    <Border VerticalAlignment="Top" HorizontalAlignment="Right" Background="#C60C0C0E" BorderBrush="{StaticResource LineBrush}" BorderThickness="1" CornerRadius="4" Padding="8,4" Margin="11">
                        <TextBlock Text="1920x1080  |  24 fps" Foreground="{StaticResource DimBrush}" FontFamily="Consolas" FontSize="10.5"/>
                    </Border>

                    <Border VerticalAlignment="Bottom" Padding="12,9">
                        <Border.Background>
                            <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                                <GradientStop Color="#000E0E10" Offset="0"/>
                                <GradientStop Color="#F00E0E10" Offset="0.45"/>
                            </LinearGradientBrush>
                        </Border.Background>
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/><ColumnDefinition Width="110"/><ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <Button x:Name="PlayPauseButton" Content="Play" Width="62"/>
                            <TextBlock x:Name="TimeText" Grid.Column="1" Text="00:00 / 01:00" Foreground="{StaticResource DimBrush}" FontFamily="Consolas" FontSize="11.5" Margin="10,0,4,0"/>
                            <Slider x:Name="SeekSlider" Grid.Column="2" Minimum="0" Maximum="60" Margin="10,0"/>
                            <TextBlock Grid.Column="3" Text="Vol" Foreground="{StaticResource MutedBrush}" FontSize="11" Margin="6,0,4,0"/>
                            <Slider x:Name="VolumeSlider" Grid.Column="4" Minimum="0" Maximum="1" Value="0.8" Margin="0,0,8,0"/>
                            <Button x:Name="FullScreenButton" Grid.Column="5" Content="Full screen" Style="{StaticResource QuietButtonStyle}"/>
                        </Grid>
                    </Border>
                </Grid>
            </Border>

            <Border Grid.Row="1" Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="1" CornerRadius="6" Margin="0,12,0,0" Padding="12,10">
                <Grid>
                    <Grid.RowDefinitions><RowDefinition Height="24"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="Storyboard" FontSize="12.5" FontWeight="SemiBold"/>
                            <TextBlock x:Name="StoryboardSummaryText" Text="Generate a preview to build the timeline" Foreground="{StaticResource MutedBrush}" FontSize="11.5" Margin="10,0,0,0"/>
                        </StackPanel>
                        <TextBlock Grid.Column="1" Text="Shuffled, no repeats side by side" Foreground="{StaticResource MutedBrush}" FontSize="11"/>
                    </Grid>
                    <ScrollViewer Grid.Row="1" HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Disabled" Margin="0,6,0,0">
                        <StackPanel x:Name="StoryboardPanel" Orientation="Horizontal"/>
                    </ScrollViewer>
                </Grid>
            </Border>
        </Grid>

        <!-- Until there is a preview to play, the stage says what is still
             needed instead of showing an empty black player. -->
        <Grid x:Name="SingleEmptyPanel" Margin="20,16,20,14">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <StackPanel>
                <TextBlock Text="Single video" FontSize="20" FontWeight="SemiBold"/>
                <TextBlock Text="Choose the photographs, the voiceover and the overlay clip, then make a 60-second preview. The player opens here once there is something to play."
                           Foreground="{StaticResource DimBrush}" FontSize="12" TextWrapping="Wrap" Margin="0,3,0,0"/>
            </StackPanel>
            <UniformGrid Grid.Row="1" Columns="3" Margin="0,16,0,0">
                <Border x:Name="SingleTileImages" Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="1" CornerRadius="7" Padding="14,12" Margin="0,0,6,0">
                    <StackPanel>
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                            <Ellipse x:Name="SingleTileImagesDot" Width="7" Height="7" Fill="{StaticResource AccentBrush}" Margin="0,0,8,0"/>
                            <TextBlock Grid.Column="1" Text="Photographs" FontSize="13" FontWeight="SemiBold"/>
                            <Button x:Name="SingleTileImagesButton" Grid.Column="2" Content="Browse" Style="{StaticResource QuietButtonStyle}" Margin="0" Padding="10,4"/>
                        </Grid>
                        <TextBlock x:Name="SingleTileImagesText" Text="No folder chosen" Foreground="{StaticResource DimBrush}" FontSize="11.5" Margin="0,8,0,0" TextTrimming="CharacterEllipsis"/>
                    </StackPanel>
                </Border>
                <Border x:Name="SingleTileAudio" Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="1" CornerRadius="7" Padding="14,12" Margin="3,0,3,0">
                    <StackPanel>
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                            <Ellipse x:Name="SingleTileAudioDot" Width="7" Height="7" Fill="{StaticResource AccentBrush}" Margin="0,0,8,0"/>
                            <TextBlock Grid.Column="1" Text="Voiceover" FontSize="13" FontWeight="SemiBold"/>
                            <Button x:Name="SingleTileAudioButton" Grid.Column="2" Content="Browse" Style="{StaticResource QuietButtonStyle}" Margin="0" Padding="10,4"/>
                        </Grid>
                        <TextBlock x:Name="SingleTileAudioText" Text="No voiceover chosen" Foreground="{StaticResource DimBrush}" FontSize="11.5" Margin="0,8,0,0" TextTrimming="CharacterEllipsis"/>
                    </StackPanel>
                </Border>
                <Border x:Name="SingleTileWatermark" Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="1" CornerRadius="7" Padding="14,12" Margin="6,0,0,0">
                    <StackPanel>
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                            <Ellipse x:Name="SingleTileWatermarkDot" Width="7" Height="7" Fill="{StaticResource AccentBrush}" Margin="0,0,8,0"/>
                            <TextBlock Grid.Column="1" Text="Overlay clip" FontSize="13" FontWeight="SemiBold"/>
                            <Button x:Name="SingleTileWatermarkButton" Grid.Column="2" Content="Browse" Style="{StaticResource QuietButtonStyle}" Margin="0" Padding="10,4"/>
                        </Grid>
                        <TextBlock x:Name="SingleTileWatermarkText" Text="No overlay chosen" Foreground="{StaticResource DimBrush}" FontSize="11.5" Margin="0,8,0,0" TextTrimming="CharacterEllipsis"/>
                    </StackPanel>
                </Border>
            </UniformGrid>
            <Grid Grid.Row="2" Margin="0,14,0,0">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="300"/></Grid.ColumnDefinitions>
                <Grid Margin="0,0,12,0">
                    <Rectangle Stroke="{StaticResource StrongLineBrush}" StrokeThickness="1" StrokeDashArray="5 4" RadiusX="7" RadiusY="7" Fill="{StaticResource PanelBrush}"/>
                    <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center" MaxWidth="380" Margin="20">
                        <Path Data="M2,6 L34,6 L34,28 L2,28 Z M14,11 L14,23 L24,17 Z" Stroke="#6E6E6A" StrokeThickness="1.4" HorizontalAlignment="Center"/>
                        <TextBlock Text="No preview yet" FontSize="15" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,12,0,0"/>
                        <TextBlock x:Name="SingleEmptyHintText" Text="Once the three sources are chosen, Preview 60s renders the first minute and opens it here with the storyboard."
                                   Foreground="{StaticResource DimBrush}" FontSize="12.5" TextWrapping="Wrap" TextAlignment="Center" Margin="0,6,0,14"/>
                        <Button x:Name="EmptyPreviewButton" Content="Preview 60s" Style="{StaticResource PrimaryButtonStyle}" HorizontalAlignment="Center" MinWidth="120"/>
                    </StackPanel>
                </Grid>
                <Border Grid.Column="1" Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="1" CornerRadius="7" Padding="14,12">
                    <Grid>
                        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                        <TextBlock Text="RECENT SINGLE VIDEOS" Foreground="{StaticResource MutedBrush}" FontSize="10" FontWeight="Bold"/>
                        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="0,8,0,0">
                            <StackPanel>
                                <StackPanel x:Name="RecentSinglePanel"/>
                                <TextBlock x:Name="RecentSingleEmptyText" Text="Finished single videos appear here. Click one to show it in its folder." Style="{StaticResource NoteText}"/>
                            </StackPanel>
                        </ScrollViewer>
                    </Grid>
                </Border>
            </Grid>
        </Grid>
            </Grid>
        </Grid>

        <!-- BATCH INSPECTOR -->
        <!-- The selected video's own files, and while a batch runs, the video
             being rendered. The shared settings open in the settings panel
             beside it, from the left rail. -->
        <Border x:Name="BatchInspectorPanel" Grid.Row="1" Grid.Column="2" Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="1,0,0,0">
            <Grid>
                <ScrollViewer x:Name="SelectedVideoView" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
                    <StackPanel Margin="16,16,16,20">
                        <TextBlock Text="SELECTED VIDEO" Foreground="{StaticResource MutedBrush}" FontSize="10" FontWeight="Bold"/>
                        <TextBlock x:Name="SelectedTitleText" Text="" FontSize="15" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,6,0,10"/>
                        <Border Height="162" Background="#2E2E34" BorderBrush="#3A3A42" BorderThickness="1" CornerRadius="5" ClipToBounds="True">
                            <Grid>
                                <TextBlock x:Name="SelectedThumbHint" Text="First image of the folder" Foreground="{StaticResource MutedBrush}" FontSize="11.5" HorizontalAlignment="Center"/>
                                <Image x:Name="SelectedThumbImage" Stretch="UniformToFill" RenderOptions.BitmapScalingMode="HighQuality"/>
                            </Grid>
                        </Border>
                        <Grid Margin="0,10,0,0">
                            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <Button x:Name="SelectedPreviewButton" Content="Preview 60s" Margin="0,0,3,0" ToolTip="Opens this video in Single video and renders its first minute in the player."/>
                            <Button x:Name="SelectedCaptionsButton" Grid.Column="1" Content="Edit captions" Style="{StaticResource QuietButtonStyle}" Margin="3,0,0,0"/>
                        </Grid>
                        <TextBlock x:Name="SelectedCaptionStatusText" Text="" Style="{StaticResource NoteText}" Margin="1,8,0,0"/>

                        <TextBlock Text="Video name" Style="{StaticResource LabelText}" Margin="0,16,0,5"/>
                        <TextBox x:Name="SelectedNameText"/>
                        <TextBlock x:Name="SelectedSavesAsText" Text="" Style="{StaticResource NoteText}" Margin="1,6,0,0"/>

                        <TextBlock Text="Save in folder" Style="{StaticResource LabelText}" Margin="0,14,0,5"/>
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                            <TextBox x:Name="SelectedOutputFolderText"/>
                            <Button x:Name="SelectedOutputBrowseButton" Grid.Column="1" Content="Browse" Style="{StaticResource QuietButtonStyle}" Margin="6,0,0,0"/>
                        </Grid>

                        <TextBlock Text="Photographs" Style="{StaticResource LabelText}" Margin="0,14,0,5"/>
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                            <TextBox x:Name="SelectedImagesText"/>
                            <Button x:Name="SelectedImagesBrowseButton" Grid.Column="1" Content="Browse" Style="{StaticResource QuietButtonStyle}" Margin="6,0,0,0"/>
                        </Grid>

                        <TextBlock Text="Voiceover" Style="{StaticResource LabelText}" Margin="0,14,0,5"/>
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                            <TextBox x:Name="SelectedAudioText"/>
                            <Button x:Name="SelectedAudioBrowseButton" Grid.Column="1" Content="Browse" Style="{StaticResource QuietButtonStyle}" Margin="6,0,0,0"/>
                        </Grid>

                        <TextBlock Text="Watermark" Style="{StaticResource LabelText}" Margin="0,14,0,5"/>
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                            <TextBox x:Name="SelectedWatermarkText"/>
                            <Button x:Name="SelectedWatermarkBrowseButton" Grid.Column="1" Content="Browse" Style="{StaticResource QuietButtonStyle}" Margin="6,0,0,0"/>
                        </Grid>

                        <Button x:Name="SelectedRemoveButton" Content="Remove from the queue" Style="{StaticResource DangerButtonStyle}" HorizontalAlignment="Left" Margin="0,18,0,0"/>
                        <Border BorderBrush="{StaticResource StrongLineBrush}" BorderThickness="2,0,0,0" Padding="11,2" Margin="1,18,0,0">
                            <TextBlock Text="Motion, captions, backdrop and export quality are set once, from the left rail, and apply to every video in the queue." Style="{StaticResource NoteText}"/>
                        </Border>
                    </StackPanel>
                </ScrollViewer>

                <StackPanel x:Name="NoSelectionView" VerticalAlignment="Center" Margin="24">
                    <TextBlock Text="No video selected" FontSize="14" FontWeight="SemiBold" HorizontalAlignment="Center"/>
                    <TextBlock Text="Select a video in the queue to see and change its files here." Foreground="{StaticResource DimBrush}" FontSize="12" TextWrapping="Wrap" TextAlignment="Center" Margin="0,6,0,0"/>
                </StackPanel>

                <ScrollViewer x:Name="NowRenderingView" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
                    <StackPanel Margin="16,16,16,20">
                        <TextBlock x:Name="NowRenderingLabel" Text="NOW RENDERING" Foreground="{StaticResource MutedBrush}" FontSize="10" FontWeight="Bold"/>
                        <TextBlock x:Name="NowRenderingTitleText" Text="" FontSize="15" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,6,0,10"/>
                        <Border Height="162" Background="#2E2E34" BorderBrush="#3A3A42" BorderThickness="1" CornerRadius="5" ClipToBounds="True">
                            <Grid>
                                <TextBlock x:Name="NowRenderingImageHint" Text="The latest finished stretch appears here" Foreground="{StaticResource MutedBrush}" FontSize="11.5" HorizontalAlignment="Center"/>
                                <Image x:Name="NowRenderingImage" Stretch="UniformToFill" RenderOptions.BitmapScalingMode="HighQuality"/>
                            </Grid>
                        </Border>
                        <UniformGrid Columns="2" Margin="0,10,0,0">
                            <Border Background="{StaticResource SunkenBrush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="1" CornerRadius="5" Padding="11,8" Margin="0,0,4,8">
                                <StackPanel><TextBlock Text="Speed" Foreground="{StaticResource MutedBrush}" FontSize="11"/><TextBlock x:Name="NowSpeedText" Text="-" FontSize="15" FontWeight="SemiBold" Margin="0,2,0,0"/></StackPanel>
                            </Border>
                            <Border Background="{StaticResource SunkenBrush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="1" CornerRadius="5" Padding="11,8" Margin="4,0,0,8">
                                <StackPanel><TextBlock Text="This video" Foreground="{StaticResource MutedBrush}" FontSize="11"/><TextBlock x:Name="NowVideoPercentText" Text="-" FontSize="15" FontWeight="SemiBold" Margin="0,2,0,0"/></StackPanel>
                            </Border>
                            <Border Background="{StaticResource SunkenBrush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="1" CornerRadius="5" Padding="11,8" Margin="0,0,4,0">
                                <StackPanel><TextBlock Text="Elapsed" Foreground="{StaticResource MutedBrush}" FontSize="11"/><TextBlock x:Name="NowElapsedText" Text="-" FontSize="15" FontWeight="SemiBold" Margin="0,2,0,0"/></StackPanel>
                            </Border>
                            <Border Background="{StaticResource SunkenBrush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="1" CornerRadius="5" Padding="11,8" Margin="4,0,0,0">
                                <StackPanel><TextBlock Text="Encoder" Foreground="{StaticResource MutedBrush}" FontSize="11"/><TextBlock x:Name="NowEncoderText" Text="-" FontSize="15" FontWeight="SemiBold" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/></StackPanel>
                            </Border>
                        </UniformGrid>
                        <TextBlock x:Name="NowRenderingStageText" Text="" Style="{StaticResource NoteText}" Margin="1,12,0,0"/>
                    </StackPanel>
                </ScrollViewer>
            </Grid>
        </Border>

        <!-- INSPECTOR -->
        <Border x:Name="SettingsPanel" Grid.Row="1" Grid.Column="2" Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="1,0,0,0">
            <Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                <Border Grid.Row="0" Padding="15,13,15,12" BorderBrush="{StaticResource LineBrush}" BorderThickness="0,0,0,1">
                    <StackPanel>
                        <!-- Batch only: these settings cover the whole queue, and
                             this returns to the video that was selected. -->
                        <Button x:Name="SettingsBackButton" Content="Back to the selected video" Style="{StaticResource QuietButtonStyle}"
                                HorizontalAlignment="Left" Padding="10,4" Margin="0,0,0,10" Visibility="Collapsed"/>
                        <TextBlock x:Name="SectionTitleText" Text="Source" FontSize="14" FontWeight="SemiBold"/>
                        <TextBlock x:Name="SectionHintText" Text="The photographs, the voiceover, and the overlay clip." Foreground="{StaticResource MutedBrush}" FontSize="11.5" TextWrapping="Wrap" Margin="0,3,0,0"/>
                    </StackPanel>
                </Border>

                <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                    <!-- Every section occupies the same cell; only the active one is visible. -->
                    <Grid Margin="15,14,15,22">

                        <!-- SOURCE -->
                        <StackPanel x:Name="SectionMedia">
                            <TextBlock Text="Photographs" Style="{StaticResource LabelText}"/>
                            <Grid>
                                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                <TextBox x:Name="ImageFolderText"/>
                                <Button x:Name="BrowseImagesButton" Grid.Column="1" Content="Browse" Style="{StaticResource QuietButtonStyle}" Margin="6,0,0,0"/>
                            </Grid>
                            <TextBlock x:Name="ImageSummaryText" Text="No folder chosen" Foreground="{StaticResource MutedBrush}" FontSize="11" Margin="1,6,0,0" TextWrapping="Wrap"/>

                            <TextBlock Text="Voiceover" Style="{StaticResource LabelText}" Margin="0,16,0,5"/>
                            <Grid>
                                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                <TextBox x:Name="AudioText"/>
                                <Button x:Name="BrowseAudioButton" Grid.Column="1" Content="Browse" Style="{StaticResource QuietButtonStyle}" Margin="6,0,0,0"/>
                            </Grid>
                            <TextBlock x:Name="AudioSummaryText" Text="No voiceover chosen" Foreground="{StaticResource MutedBrush}" FontSize="11" Margin="1,6,0,0" TextWrapping="Wrap"/>

                            <TextBlock Text="Overlay clip" Style="{StaticResource LabelText}" Margin="0,16,0,5"/>
                            <Grid>
                                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                <TextBox x:Name="WatermarkText"/>
                                <Button x:Name="BrowseWatermarkButton" Grid.Column="1" Content="Browse" Style="{StaticResource QuietButtonStyle}" Margin="6,0,0,0"/>
                            </Grid>
                            <TextBlock x:Name="WatermarkSummaryText" Text="No overlay chosen" Foreground="{StaticResource MutedBrush}" FontSize="11" Margin="1,6,0,0" TextWrapping="Wrap"/>

                            <Border BorderBrush="{StaticResource StrongLineBrush}" BorderThickness="2,0,0,0" Padding="11,2" Margin="1,20,0,0">
                                <StackPanel>
                                    <TextBlock Text="Only files directly inside the folder are used. Sub-folders are ignored." Style="{StaticResource NoteText}"/>
                                    <TextBlock Text="JPG, JPEG, PNG and WEBP are supported." Style="{StaticResource NoteText}" Margin="0,5,0,0"/>
                                </StackPanel>
                            </Border>
                        </StackPanel>

                        <!-- MOTION -->
                        <StackPanel x:Name="SectionMotion" Visibility="Collapsed">
                            <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="76"/></Grid.ColumnDefinitions>
                                <TextBlock Text="Shortest hold" Style="{StaticResource RowLabel}"/>
                                <TextBox x:Name="MinimumDurationText" Grid.Column="1" Text="5.0" HorizontalContentAlignment="Center"/></Grid>
                            <Grid Margin="0,7"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="76"/></Grid.ColumnDefinitions>
                                <TextBlock Text="Longest hold" Style="{StaticResource RowLabel}"/>
                                <TextBox x:Name="MaximumDurationText" Grid.Column="1" Text="7.0" HorizontalContentAlignment="Center"/></Grid>
                            <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="76"/></Grid.ColumnDefinitions>
                                <TextBlock Text="Maximum zoom %" Style="{StaticResource RowLabel}"/>
                                <TextBox x:Name="ZoomText" Grid.Column="1" Text="110" HorizontalContentAlignment="Center"/></Grid>
                            <Grid Margin="0,14,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="118"/></Grid.ColumnDefinitions>
                                <TextBlock Text="Motion quality" Style="{StaticResource RowLabel}"/>
                                <ComboBox x:Name="MotionQualityCombo" Grid.Column="1" SelectedIndex="1">
                                    <ComboBoxItem Content="Fast"/>
                                    <ComboBoxItem Content="Balanced"/>
                                    <ComboBoxItem Content="Best"/>
                                </ComboBox></Grid>
                            <CheckBox x:Name="CrossfadeCheckBox" Content="Cross-dissolve between images" Margin="0,14,0,0"/>
                            <Grid x:Name="CrossfadeDurationRow" Margin="0,7,0,0" IsEnabled="False"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="76"/></Grid.ColumnDefinitions>
                                <TextBlock Text="Dissolve seconds" Style="{StaticResource RowLabel}"/>
                                <TextBox x:Name="CrossfadeSecondsText" Grid.Column="1" Text="0.5" HorizontalContentAlignment="Center"/></Grid>
                            <Border BorderBrush="{StaticResource StrongLineBrush}" BorderThickness="2,0,0,0" Padding="11,2" Margin="1,20,0,0">
                                <StackPanel>
                                    <TextBlock Text="Each image holds for a random time inside this range." Style="{StaticResource NoteText}"/>
                                    <TextBlock Text="It also zooms in or out and drifts slowly across one axis. Both move at a constant rate, so the motion never stalls before a cut." Style="{StaticResource NoteText}" Margin="0,6,0,0"/>
                                    <TextBlock x:Name="CrossfadeNoteText" Text="Images cut straight from one to the next. A dissolve looks more finished, but measured about a third slower to render, because both images have to be drawn during the overlap." Style="{StaticResource NoteText}" Margin="0,6,0,0"/>
                                </StackPanel>
                            </Border>
                        </StackPanel>

                        <!-- CAPTIONS -->
                        <StackPanel x:Name="SectionCaptions" Visibility="Collapsed">
                            <TextBlock Text="Where they appear" Style="{StaticResource LabelText}"/>
                            <Border BorderBrush="{StaticResource LineBrush}" BorderThickness="1" CornerRadius="5" Background="{StaticResource SunkenBrush}">
                                <UniformGrid x:Name="CaptionModePanel" Rows="1" Columns="4"/>
                            </Border>
                            <!-- The mode and preset combo boxes remain the state the rest of
                                 the application reads. They are hidden because the row of
                                 buttons above and the swatches below drive them, which keeps
                                 every existing handler working untouched. -->
                            <ComboBox x:Name="CaptionModeCombo" Visibility="Collapsed" SelectedIndex="1">
                                <ComboBoxItem Content="Off"/><ComboBoxItem Content="SRT only"/><ComboBoxItem Content="Burned only"/><ComboBoxItem Content="Burned + SRT"/>
                            </ComboBox>

                            <TextBlock Text="Look" Style="{StaticResource LabelText}" Margin="0,16,0,5"/>
                            <UniformGrid x:Name="CaptionPresetSwatchPanel" Columns="3"/>
                            <ComboBox x:Name="CaptionPresetCombo" Visibility="Collapsed" SelectedIndex="0">
                                <ComboBoxItem Content="1. Clean YouTube"/><ComboBoxItem Content="2. Modern News"/><ComboBoxItem Content="3. Minimal Shadow"/>
                                <ComboBoxItem Content="4. Translucent Box"/><ComboBoxItem Content="5. Yellow Headline"/><ComboBoxItem Content="6. Cyan Accent"/>
                                <ComboBoxItem Content="7. Documentary Serif"/><ComboBoxItem Content="8. Yellow Emphasis"/><ComboBoxItem Content="9. Upper Safe"/>
                                <ComboBoxItem Content="10. Compact Broadcast"/>
                            </ComboBox>
                            <TextBlock x:Name="CaptionPresetHelpText" Text="White semibold text, centered safely above the bottom." Style="{StaticResource NoteText}" Margin="1,7,0,0"/>

                            <StackPanel x:Name="SingleOnlyCaptionPanel">
                                <Grid Margin="0,14,0,0">
                                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                    <Button x:Name="GenerateCaptionsButton" Content="Generate" Margin="0,0,3,0"/>
                                    <Button x:Name="EditCaptionsButton" Grid.Column="1" Content="Edit text" Style="{StaticResource QuietButtonStyle}" Margin="3,0,0,0"/>
                                </Grid>
                                <TextBlock x:Name="CaptionStatusText" Text="Select a voiceover; captions are generated on this computer." Style="{StaticResource NoteText}" Margin="1,8,0,0"/>
                            </StackPanel>
                            <TextBlock x:Name="BatchCaptionNoteText" Visibility="Collapsed" Style="{StaticResource NoteText}" Margin="1,12,0,0"
                                       Text="Each video's captions come from its own voiceover and are generated during the batch if they are not ready. To check or correct one first, select it in the queue and choose Edit captions."/>

                            <TextBlock Text="Fine tuning" Style="{StaticResource LabelText}" Margin="0,18,0,5"/>
                            <Border BorderBrush="{StaticResource LineBrush}" BorderThickness="1" CornerRadius="5" Background="{StaticResource SunkenBrush}">
                                <UniformGrid Rows="1" Columns="3">
                                    <Button x:Name="CaptionTabTypeButton" Style="{StaticResource TabButtonStyle}" Content="Type"/>
                                    <Button x:Name="CaptionTabColourButton" Style="{StaticResource TabButtonStyle}" Content="Colour"/>
                                    <Button x:Name="CaptionTabPositionButton" Style="{StaticResource TabButtonStyle}" Content="Position"/>
                                </UniformGrid>
                            </Border>

                            <Grid Margin="0,12,0,0">
                                <StackPanel x:Name="CaptionGroupType">
                                    <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="88"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                        <TextBlock Text="Font" Style="{StaticResource RowLabel}"/>
                                        <ComboBox x:Name="CaptionFontCombo" Grid.Column="1" SelectedIndex="0">
                                            <ComboBoxItem Content="Segoe UI Semibold"/><ComboBoxItem Content="Segoe UI"/><ComboBoxItem Content="Arial"/><ComboBoxItem Content="Arial Narrow"/>
                                            <ComboBoxItem Content="Georgia"/><ComboBoxItem Content="Calibri"/><ComboBoxItem Content="Verdana"/><ComboBoxItem Content="Trebuchet MS"/>
                                        </ComboBox></Grid>
                                    <CheckBox x:Name="CaptionBoldCheckBox" Content="Bold text" IsChecked="True" Margin="88,6,0,4"/>
                                    <Grid Margin="0,4"><Grid.ColumnDefinitions><ColumnDefinition Width="88"/><ColumnDefinition Width="*"/><ColumnDefinition Width="42"/></Grid.ColumnDefinitions>
                                        <TextBlock Text="Size" Style="{StaticResource RowLabel}"/>
                                        <Slider x:Name="CaptionSizeSlider" Grid.Column="1" Minimum="10" Maximum="36" Value="16" TickFrequency="1"/>
                                        <TextBlock x:Name="CaptionSizeValueText" Grid.Column="2" Text="16" Style="{StaticResource ValueText}"/></Grid>
                                    <Grid Margin="0,4"><Grid.ColumnDefinitions><ColumnDefinition Width="88"/><ColumnDefinition Width="*"/><ColumnDefinition Width="42"/></Grid.ColumnDefinitions>
                                        <TextBlock Text="Outline" Style="{StaticResource RowLabel}"/>
                                        <Slider x:Name="CaptionOutlineSlider" Grid.Column="1" Minimum="0" Maximum="8" Value="2" TickFrequency="0.5"/>
                                        <TextBlock x:Name="CaptionOutlineValueText" Grid.Column="2" Text="2" Style="{StaticResource ValueText}"/></Grid>
                                    <Grid Margin="0,4"><Grid.ColumnDefinitions><ColumnDefinition Width="88"/><ColumnDefinition Width="*"/><ColumnDefinition Width="42"/></Grid.ColumnDefinitions>
                                        <TextBlock Text="Shadow" Style="{StaticResource RowLabel}"/>
                                        <Slider x:Name="CaptionShadowSlider" Grid.Column="1" Minimum="0" Maximum="8" Value="0" TickFrequency="0.5"/>
                                        <TextBlock x:Name="CaptionShadowValueText" Grid.Column="2" Text="0" Style="{StaticResource ValueText}"/></Grid>
                                    <Grid Margin="0,4"><Grid.ColumnDefinitions><ColumnDefinition Width="88"/><ColumnDefinition Width="*"/><ColumnDefinition Width="42"/></Grid.ColumnDefinitions>
                                        <TextBlock Text="Words / line" Style="{StaticResource RowLabel}"/>
                                        <Slider x:Name="CaptionWordsPerLineSlider" Grid.Column="1" Minimum="3" Maximum="20" Value="8" TickFrequency="1" IsSnapToTickEnabled="True"/>
                                        <TextBlock x:Name="CaptionWordsPerLineValueText" Grid.Column="2" Text="8" Style="{StaticResource ValueText}"/></Grid>
                                    <Grid Margin="0,4"><Grid.ColumnDefinitions><ColumnDefinition Width="88"/><ColumnDefinition Width="*"/><ColumnDefinition Width="42"/></Grid.ColumnDefinitions>
                                        <TextBlock Text="Line height" Style="{StaticResource RowLabel}"/>
                                        <Slider x:Name="CaptionLineSpacingSlider" Grid.Column="1" Minimum="0.8" Maximum="1.5" Value="1" TickFrequency="0.05"/>
                                        <TextBlock x:Name="CaptionLineSpacingValueText" Grid.Column="2" Text="1.00" Style="{StaticResource ValueText}"/></Grid>
                                </StackPanel>

                                <StackPanel x:Name="CaptionGroupColour" Visibility="Collapsed">
                                    <Grid Margin="0,4"><Grid.ColumnDefinitions><ColumnDefinition Width="88"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                        <TextBlock Text="Text" Style="{StaticResource RowLabel}"/>
                                        <TextBox x:Name="CaptionTextColorText" Grid.Column="1" Text="#FFFFFF"/>
                                        <Button x:Name="CaptionTextColorButton" Grid.Column="2" Content="Pick" Style="{StaticResource QuietButtonStyle}" Margin="6,0,0,0"/></Grid>
                                    <Grid Margin="0,4"><Grid.ColumnDefinitions><ColumnDefinition Width="88"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                        <TextBlock Text="Outline" Style="{StaticResource RowLabel}"/>
                                        <TextBox x:Name="CaptionOutlineColorText" Grid.Column="1" Text="#000000"/>
                                        <Button x:Name="CaptionOutlineColorButton" Grid.Column="2" Content="Pick" Style="{StaticResource QuietButtonStyle}" Margin="6,0,0,0"/></Grid>
                                    <Grid Margin="0,4"><Grid.ColumnDefinitions><ColumnDefinition Width="88"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                        <TextBlock Text="Box" Style="{StaticResource RowLabel}"/>
                                        <TextBox x:Name="CaptionBackgroundColorText" Grid.Column="1" Text="#000000"/>
                                        <Button x:Name="CaptionBackgroundColorButton" Grid.Column="2" Content="Pick" Style="{StaticResource QuietButtonStyle}" Margin="6,0,0,0"/></Grid>
                                    <Grid Margin="0,4"><Grid.ColumnDefinitions><ColumnDefinition Width="88"/><ColumnDefinition Width="*"/><ColumnDefinition Width="42"/></Grid.ColumnDefinitions>
                                        <TextBlock Text="Box opacity" Style="{StaticResource RowLabel}"/>
                                        <Slider x:Name="CaptionBackgroundOpacitySlider" Grid.Column="1" Minimum="0" Maximum="100" Value="0" TickFrequency="5"/>
                                        <TextBlock x:Name="CaptionBackgroundOpacityValueText" Grid.Column="2" Text="0%" Style="{StaticResource ValueText}"/></Grid>
                                </StackPanel>

                                <StackPanel x:Name="CaptionGroupPosition" Visibility="Collapsed">
                                    <Grid Margin="0,4"><Grid.ColumnDefinitions><ColumnDefinition Width="88"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                        <TextBlock Text="Alignment" Style="{StaticResource RowLabel}"/>
                                        <ComboBox x:Name="CaptionAlignmentCombo" Grid.Column="1" SelectedIndex="1">
                                            <ComboBoxItem Content="Left"/><ComboBoxItem Content="Center"/><ComboBoxItem Content="Right"/>
                                        </ComboBox></Grid>
                                    <Grid Margin="0,4"><Grid.ColumnDefinitions><ColumnDefinition Width="88"/><ColumnDefinition Width="*"/><ColumnDefinition Width="42"/></Grid.ColumnDefinitions>
                                        <TextBlock Text="Position X" Style="{StaticResource RowLabel}"/>
                                        <Slider x:Name="CaptionPositionXSlider" Grid.Column="1" Minimum="5" Maximum="95" Value="50"/>
                                        <TextBlock x:Name="CaptionPositionXValueText" Grid.Column="2" Text="50%" Style="{StaticResource ValueText}"/></Grid>
                                    <Grid Margin="0,4"><Grid.ColumnDefinitions><ColumnDefinition Width="88"/><ColumnDefinition Width="*"/><ColumnDefinition Width="42"/></Grid.ColumnDefinitions>
                                        <TextBlock Text="Position Y" Style="{StaticResource RowLabel}"/>
                                        <Slider x:Name="CaptionPositionYSlider" Grid.Column="1" Minimum="5" Maximum="95" Value="70"/>
                                        <TextBlock x:Name="CaptionPositionYValueText" Grid.Column="2" Text="70%" Style="{StaticResource ValueText}"/></Grid>
                                    <Grid Margin="0,4"><Grid.ColumnDefinitions><ColumnDefinition Width="88"/><ColumnDefinition Width="*"/><ColumnDefinition Width="42"/></Grid.ColumnDefinitions>
                                        <TextBlock Text="Max width" Style="{StaticResource RowLabel}"/>
                                        <Slider x:Name="CaptionMaxWidthSlider" Grid.Column="1" Minimum="25" Maximum="95" Value="82"/>
                                        <TextBlock x:Name="CaptionMaxWidthValueText" Grid.Column="2" Text="82%" Style="{StaticResource ValueText}"/></Grid>
                                    <TextBlock Text="Drag the caption in the player to move it. Drag the tungsten corner to resize it." Foreground="{StaticResource AccentBrush}" FontSize="11" TextWrapping="Wrap" Margin="1,10,0,0"/>
                                </StackPanel>
                            </Grid>
                        </StackPanel>

                        <!-- BACKDROP -->
                        <StackPanel x:Name="SectionBlanking" Visibility="Collapsed">
                            <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="46"/></Grid.ColumnDefinitions>
                                <TextBlock Text="Blur" Style="{StaticResource RowLabel}"/>
                                <TextBlock x:Name="BlurValueText" Grid.Column="1" Text="40" Style="{StaticResource ValueText}"/></Grid>
                            <Slider x:Name="BlurSlider" Minimum="0" Maximum="100" Value="40" TickFrequency="1" IsSnapToTickEnabled="True" Margin="0,4,0,0"/>
                            <Grid Margin="0,16,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="46"/></Grid.ColumnDefinitions>
                                <TextBlock Text="Brightness" Style="{StaticResource RowLabel}"/>
                                <TextBlock x:Name="BrightnessValueText" Grid.Column="1" Text="65%" Style="{StaticResource ValueText}"/></Grid>
                            <Slider x:Name="BrightnessSlider" Minimum="20" Maximum="100" Value="65" TickFrequency="1" IsSnapToTickEnabled="True" Margin="0,4,0,0"/>
                            <Border BorderBrush="{StaticResource StrongLineBrush}" BorderThickness="2,0,0,0" Padding="11,2" Margin="1,22,0,0">
                                <TextBlock Text="A photograph that does not fill the 16:9 frame is shown whole, over a blurred and darkened copy of itself. These two controls shape that backdrop." Style="{StaticResource NoteText}"/>
                            </Border>
                        </StackPanel>

                        <!-- EXPORT -->
                        <StackPanel x:Name="SectionExport" Visibility="Collapsed">
                            <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="104"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                <TextBlock Text="Quality" Style="{StaticResource RowLabel}"/>
                                <ComboBox x:Name="QualityCombo" Grid.Column="1" SelectedIndex="3">
                                    <ComboBoxItem Content="Compact"/><ComboBoxItem Content="Balanced"/><ComboBoxItem Content="High"/><ComboBoxItem Content="YouTube"/>
                                </ComboBox></Grid>
                            <Grid Margin="0,9"><Grid.ColumnDefinitions><ColumnDefinition Width="104"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                <TextBlock Text="Format" Style="{StaticResource RowLabel}"/>
                                <TextBlock Grid.Column="1" Text="1080p  H.264  24 fps" Foreground="{StaticResource DimBrush}" FontFamily="Consolas" FontSize="11.5"/></Grid>
                            <StackPanel x:Name="SingleOnlyExportPanel">
                                <Grid Margin="0,3"><Grid.ColumnDefinitions><ColumnDefinition Width="104"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                    <TextBlock Text="Estimated size" Style="{StaticResource RowLabel}"/>
                                    <TextBlock x:Name="EstimateText" Grid.Column="1" Text="Scan voiceover first" Foreground="{StaticResource AccentBrush}" FontSize="12"/></Grid>
                                <TextBlock Text="Save to" Style="{StaticResource LabelText}" Margin="0,16,0,5"/>
                                <Grid>
                                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                    <TextBox x:Name="OutputText"/>
                                    <Button x:Name="BrowseOutputButton" Grid.Column="1" Content="Save as" Style="{StaticResource QuietButtonStyle}" Margin="6,0,0,0"/>
                                </Grid>
                            </StackPanel>
                            <TextBlock x:Name="BatchExportNoteText" Visibility="Collapsed" Style="{StaticResource NoteText}" Margin="1,12,0,0"
                                       Text="Each video is saved under its own name in its own folder, shown in the panel beside the queue. The time and size of the whole batch are estimated at the bottom of the window."/>
                        </StackPanel>

                    </Grid>
                </ScrollViewer>
            </Grid>
        </Border>

        <!-- FOOTER -->
        <Border x:Name="StatusPanel" Grid.Row="2" Grid.ColumnSpan="3" Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="0,1,0,0">
            <Grid Margin="16,0">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel VerticalAlignment="Center" Margin="0,0,24,0">
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBlock x:Name="StatusText" Text="Ready to create" FontSize="12.5" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                        <!-- What is still missing, rather than a button that is
                             simply greyed out with no reason given. -->
                        <StackPanel x:Name="ReadinessPanel" Grid.Column="1" Orientation="Horizontal" Margin="16,0,0,0"/>
                        <TextBlock x:Name="RenderEtaText" Grid.Column="2" Text="" Foreground="{StaticResource DimBrush}" FontFamily="Consolas" FontSize="11.5"/>
                    </Grid>
                    <ProgressBar x:Name="RenderProgress" Height="5" Minimum="0" Maximum="100" Value="0" Margin="0,8,0,0"/>
                    <TextBlock x:Name="RenderDetailText" Text="" Foreground="{StaticResource MutedBrush}" FontSize="10.5" Margin="0,5,0,0"/>
                </StackPanel>
                <StackPanel x:Name="SingleFooterButtons" Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Visibility="Collapsed">
                    <Button x:Name="PreviewButton" Content="Preview 60s" Style="{StaticResource QuietButtonStyle}" MinWidth="104"/>
                    <Button x:Name="FinalButton" Content="Render final" Style="{StaticResource PrimaryButtonStyle}" MinWidth="122" IsEnabled="False"/>
                    <Button x:Name="CancelButton" Content="Cancel" Style="{StaticResource DangerButtonStyle}" IsEnabled="False"/>
                    <Button x:Name="OpenFolderButton" Content="Open folder" Style="{StaticResource QuietButtonStyle}" IsEnabled="False"/>
                </StackPanel>
                <StackPanel x:Name="BatchFooterButtons" Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock x:Name="BatchEstimateText" Text="" Foreground="{StaticResource DimBrush}" FontFamily="Consolas" FontSize="11.5" Margin="0,0,14,0"
                               ToolTip="Estimated from the voiceover lengths and this computer's measured render speed. It settles once a batch has been rendered here."/>
                    <Button x:Name="RenderAllButton" Content="Render all" Style="{StaticResource PrimaryButtonStyle}" MinWidth="122"/>
                    <!-- Pausing keeps every finished video and every finished
                         stretch of the one in progress; Resume carries on from there. -->
                    <Button x:Name="BatchPauseButton" Content="Pause" Style="{StaticResource DangerButtonStyle}" MinWidth="80" Visibility="Collapsed"/>
                    <Button x:Name="BatchResumeButton" Content="Resume" Style="{StaticResource PrimaryButtonStyle}" MinWidth="100" Visibility="Collapsed"/>
                    <Button x:Name="BatchOpenFolderButton" Content="Open output folder" Style="{StaticResource QuietButtonStyle}" IsEnabled="False"/>
                </StackPanel>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

$xmlReader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($xmlReader)
$window.Add_SourceInitialized({
    try {
        $handle = [Windows.Interop.WindowInteropHelper]::new($window).Handle
        $enabled = 1
        [void][CreatorFlowWindowTheme]::DwmSetWindowAttribute($handle, 20, [ref]$enabled, 4)
    }
    catch {}
})

$controlNames = @(
    'RootGrid', 'NavigationColumn', 'NavigationPanel', 'SettingsColumn', 'SettingsPanel', 'PlayerPanel', 'StatusPanel',
    'EncoderText', 'OpenProjectButton', 'SaveProjectButton', 'RenderHistoryButton',
    'CheckUpdatesButton', 'AppSubtitleText',
    # Batch and Single video are two halves of one window.
    'ModeBatchButton', 'ModeBatchLabel', 'BatchCountText', 'ModeSingleButton', 'ModeSingleLabel',
    'BatchView', 'SingleView', 'BatchRailPanel', 'SingleRailPanel', 'BatchInspectorPanel',
    'SingleFooterButtons', 'BatchFooterButtons', 'SingleOnlyExportPanel', 'BatchExportNoteText',
    'SingleOnlyCaptionPanel', 'BatchCaptionNoteText', 'SettingsBackButton',
    # The queue.
    'ChannelFilterPanel', 'BatchNavMotionButton', 'BatchNavCaptionsButton', 'BatchNavBlankingButton', 'BatchNavExportButton',
    'BatchNavMotionSummaryText', 'BatchNavCaptionsSummaryText', 'BatchNavBlankingSummaryText', 'BatchNavExportSummaryText',
    'BatchHeadingText', 'BatchSubheadingText', 'QueueActionsPanel', 'ScanChannelsButton', 'AddVideoButton', 'SavedProjectsButton',
    'ClearFinishedButton', 'ShowQueueButton', 'DefaultWatermarkRow', 'BatchWatermarkText', 'BrowseBatchWatermarkButton',
    'ScanSummaryBorder', 'ScanSummaryText', 'ScanSkippedButton', 'QueueTableHost', 'QueueRowsPanel', 'QueueEmptyPanel',
    'EmptyScanButton', 'EmptyAddButton', 'RenderTableHost', 'RenderRowsPanel',
    'BatchEstimateText', 'RenderAllButton', 'BatchPauseButton', 'BatchResumeButton', 'BatchOpenFolderButton',
    # The selected video, and the one being rendered.
    'SelectedVideoView', 'NoSelectionView', 'SelectedTitleText', 'SelectedThumbHint', 'SelectedThumbImage',
    'SelectedPreviewButton', 'SelectedCaptionsButton', 'SelectedCaptionStatusText', 'SelectedNameText', 'SelectedSavesAsText',
    'SelectedOutputFolderText', 'SelectedOutputBrowseButton', 'SelectedImagesText', 'SelectedImagesBrowseButton',
    'SelectedAudioText', 'SelectedAudioBrowseButton', 'SelectedWatermarkText', 'SelectedWatermarkBrowseButton', 'SelectedRemoveButton',
    'NowRenderingView', 'NowRenderingLabel', 'NowRenderingTitleText', 'NowRenderingImageHint', 'NowRenderingImage',
    'NowSpeedText', 'NowVideoPercentText', 'NowElapsedText', 'NowEncoderText', 'NowRenderingStageText',
    # Single video before there is a preview to play.
    'QueuePreviewBanner', 'QueuePreviewBannerText', 'BackToQueueButton', 'SingleEmptyPanel', 'SingleEmptyHintText', 'EmptyPreviewButton',
    'SingleTileImagesDot', 'SingleTileImagesText', 'SingleTileImagesButton',
    'SingleTileAudioDot', 'SingleTileAudioText', 'SingleTileAudioButton',
    'SingleTileWatermarkDot', 'SingleTileWatermarkText', 'SingleTileWatermarkButton',
    'RecentSinglePanel', 'RecentSingleEmptyText',
    'MotionQualityCombo', 'CrossfadeCheckBox', 'CrossfadeSecondsText', 'CrossfadeDurationRow',
    'NavMediaButton', 'NavMotionButton', 'NavCaptionsButton', 'NavBlankingButton', 'NavExportButton',
    'SectionTitleText', 'SectionHintText',
    'SectionMedia', 'SectionMotion', 'SectionCaptions', 'SectionBlanking', 'SectionExport',
    'ImageFolderText', 'BrowseImagesButton', 'AudioText', 'BrowseAudioButton',
    'WatermarkText', 'BrowseWatermarkButton', 'OutputText', 'BrowseOutputButton',
    'MinimumDurationText', 'MaximumDurationText', 'ZoomText',
    'CaptionModeCombo', 'CaptionPresetCombo', 'CaptionPresetHelpText', 'GenerateCaptionsButton', 'EditCaptionsButton', 'CaptionStatusText',
    'CaptionOverlayCanvas', 'LiveCaptionBorder', 'LiveCaptionText', 'CaptionMoveThumb', 'CaptionResizeThumb',
    'CaptionFontCombo', 'CaptionBoldCheckBox', 'CaptionSizeSlider', 'CaptionSizeValueText',
    'CaptionTextColorText', 'CaptionTextColorButton', 'CaptionOutlineColorText', 'CaptionOutlineColorButton', 'CaptionOutlineSlider', 'CaptionOutlineValueText',
    'CaptionShadowSlider', 'CaptionShadowValueText', 'CaptionBackgroundColorText', 'CaptionBackgroundColorButton', 'CaptionBackgroundOpacitySlider', 'CaptionBackgroundOpacityValueText',
    'CaptionAlignmentCombo', 'CaptionPositionXSlider', 'CaptionPositionXValueText', 'CaptionPositionYSlider', 'CaptionPositionYValueText',
    'CaptionMaxWidthSlider', 'CaptionMaxWidthValueText', 'CaptionWordsPerLineSlider', 'CaptionWordsPerLineValueText', 'CaptionLineSpacingSlider', 'CaptionLineSpacingValueText',
    'BlurSlider', 'BlurValueText', 'BrightnessSlider', 'BrightnessValueText',
    'QualityCombo', 'EstimateText', 'PreviewMedia', 'PlayPauseButton',
    'SeekSlider', 'TimeText', 'VolumeSlider', 'FullScreenButton',
    'StoryboardPanel', 'StoryboardSummaryText',
    'StatusText', 'PreviewButton', 'FinalButton', 'CancelButton',
    'OpenFolderButton', 'RenderProgress',
    # Each workflow step reports its own state, so the rail shows what is set
    # and what is not without anyone having to click through all five.
    'NavMediaBadge', 'NavMediaBadgeText', 'NavMediaSummaryText',
    'NavMotionBadge', 'NavMotionBadgeText', 'NavMotionSummaryText',
    'NavCaptionsBadge', 'NavCaptionsBadgeText', 'NavCaptionsSummaryText',
    'NavBlankingBadge', 'NavBlankingBadgeText', 'NavBlankingSummaryText',
    'NavExportBadge', 'NavExportBadgeText', 'NavExportSummaryText',
    'HistoryCountBadge', 'HistoryCountText',
    # What was actually found behind each chosen path.
    'ImageSummaryText', 'AudioSummaryText', 'WatermarkSummaryText',
    # Caption mode and preset are chosen from buttons and swatches now.
    'CaptionModePanel', 'CaptionPresetSwatchPanel',
    'CaptionTabTypeButton', 'CaptionTabColourButton', 'CaptionTabPositionButton',
    'CaptionGroupType', 'CaptionGroupColour', 'CaptionGroupPosition',
    # A long render needs a finish time, not a percentage.
    'ReadinessPanel', 'RenderEtaText', 'RenderDetailText',
    'AppLogoImage'
)
foreach ($name in $controlNames) {
    $control = $window.FindName($name)
    if ($null -eq $control) {
        throw "The window template is missing the control '$name'."
    }
    Set-Variable -Name $name -Value $control -Scope Script
}

# The left rail switches which settings section is visible. Each entry carries
# the section panel, its nav button, and the heading shown above the panel.
$script:SettingsSections = [ordered]@{
    'Media'    = @{ Panel = $SectionMedia;    Button = $NavMediaButton;    Badge = $NavMediaBadge;    BadgeText = $NavMediaBadgeText;    Summary = $NavMediaSummaryText;    Step = '1'; Title = 'Source';   Hint = 'The photographs, the voiceover, and the overlay clip that screens over the top.' }
    'Motion'   = @{ Panel = $SectionMotion;   Button = $NavMotionButton;   Badge = $NavMotionBadge;   BadgeText = $NavMotionBadgeText;   Summary = $NavMotionSummaryText;   Step = '2'; Title = 'Motion';   Hint = 'How long each image holds, and how far it zooms.' }
    'Captions' = @{ Panel = $SectionCaptions; Button = $NavCaptionsButton; Badge = $NavCaptionsBadge; BadgeText = $NavCaptionsBadgeText; Summary = $NavCaptionsSummaryText; Step = '3'; Title = 'Captions'; Hint = 'Generated from the voiceover on this computer. Nothing is uploaded.' }
    'Blanking' = @{ Panel = $SectionBlanking; Button = $NavBlankingButton; Badge = $NavBlankingBadge; BadgeText = $NavBlankingBadgeText; Summary = $NavBlankingSummaryText; Step = '4'; Title = 'Backdrop'; Hint = 'The blurred fill behind a photograph that does not reach the edges of the frame.' }
    'Export'   = @{ Panel = $SectionExport;   Button = $NavExportButton;   Badge = $NavExportBadge;   BadgeText = $NavExportBadgeText;   Summary = $NavExportSummaryText;   Step = '5'; Title = 'Export';   Hint = 'Quality target and where the finished MP4 is written.' }
}

function New-ToolBrush {
    param([string]$Hex)
    return [Windows.Media.BrushConverter]::new().ConvertFromString($Hex)
}

$script:AppIconImage = $null

function Get-AppIconImage {
    # Loaded once and cached. OnLoad caching means the file is not held open,
    # so an update can replace the artwork while the tool is running.
    if ($null -ne $script:AppIconImage) { return $script:AppIconImage }
    foreach ($name in @('CreatorFlow.ico', 'CreatorFlow.png')) {
        $path = Join-Path $script:AppRoot "Assets\$name"
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try {
            $image = [Windows.Media.Imaging.BitmapImage]::new()
            $image.BeginInit()
            $image.UriSource = [Uri]::new($path)
            $image.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $image.EndInit()
            $image.Freeze()
            $script:AppIconImage = $image
            return $image
        }
        catch {}
    }
    return $null
}

function Set-WindowIcon {
    param([Windows.Window]$Target)
    $icon = Get-AppIconImage
    if ($null -ne $icon -and $null -ne $Target) {
        try { $Target.Icon = $icon } catch {}
    }
}

# The one saturated colour in the window, and the greys it sits on. Kept in one
# place so the palette cannot drift as handlers are added.
$script:AccentBrush = New-ToolBrush '#E0913F'
$script:AccentTintBrush = New-ToolBrush '#2A2119'
$script:AccentDeepBrush = New-ToolBrush '#8A5424'
$script:OkBrush = New-ToolBrush '#7CA97C'
$script:OkTintBrush = New-ToolBrush '#1D241D'
$script:TextBrush = New-ToolBrush '#E9E9E6'
$script:DimBrush = New-ToolBrush '#A3A39E'
$script:MutedBrush = New-ToolBrush '#7E7E7A'
$script:StrongLineBrush = New-ToolBrush '#41414A'
$script:StepBadgeInk = New-ToolBrush '#1C1206'
$script:TransparentBrush = [Windows.Media.Brushes]::Transparent
$script:RaisedBrush = New-ToolBrush '#26262B'
$script:SunkenBrush = New-ToolBrush '#101012'
$script:LineBrush = New-ToolBrush '#33333A'
$script:RowLineBrush = New-ToolBrush '#2A2A30'
$script:ThumbFillBrush = New-ToolBrush '#2E2E34'
$script:BadBrush = New-ToolBrush '#D88A82'
$script:BadTintBrush = New-ToolBrush '#2E1F1E'
$script:OkTextBrush = New-ToolBrush '#8FBF8F'
$script:RenderingRowBrush = New-ToolBrush '#211C17'

function Set-StepComplete {
    # A step reports itself done with a tick and a green badge, or unfinished
    # with its number. The active step overrides both, because where you are
    # matters more on the rail than what you have already settled.
    param([string]$Name, [bool]$Complete, [string]$Summary)
    if (-not $script:SettingsSections.Contains($Name)) { return }
    $entry = $script:SettingsSections[$Name]
    $entry.Complete = $Complete
    if ($PSBoundParameters.ContainsKey('Summary')) {
        $entry.Summary.Text = $Summary
    }
    if ($script:ActiveSection -ne $Name) { Update-StepBadge -Name $Name }
}

function Update-StepBadge {
    param([string]$Name)
    $entry = $script:SettingsSections[$Name]
    $isActive = ($script:ActiveSection -eq $Name)
    $isComplete = [bool](Get-OptionalHashValue -Table $entry -Key 'Complete')

    if ($isActive) {
        $entry.Badge.Background = $script:AccentBrush
        $entry.Badge.BorderBrush = $script:AccentBrush
        $entry.BadgeText.Foreground = $script:StepBadgeInk
        $entry.BadgeText.Text = [string]$entry.Step
    }
    elseif ($isComplete) {
        $entry.Badge.Background = $script:OkTintBrush
        $entry.Badge.BorderBrush = $script:OkBrush
        $entry.BadgeText.Foreground = $script:OkBrush
        # A tick rather than the number: the number answers "where am I", and
        # once a step is behind you that is no longer the question.
        $entry.BadgeText.Text = [char]0x2713
    }
    else {
        $entry.Badge.Background = $script:TransparentBrush
        $entry.Badge.BorderBrush = $script:StrongLineBrush
        $entry.BadgeText.Foreground = $script:MutedBrush
        $entry.BadgeText.Text = [string]$entry.Step
    }
}

function Get-OptionalHashValue {
    param([hashtable]$Table, [string]$Key)
    if ($Table.ContainsKey($Key)) { return $Table[$Key] }
    return $null
}

function Set-ActiveSection {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not $script:SettingsSections.Contains($Name)) { return }
    $script:ActiveSection = $Name
    # Batch opens the shared sections here too; Single video returns to the
    # section it was last on, not to whichever one the batch rail opened.
    if ($script:AppMode -eq 'Single') { $script:SingleActiveSection = $Name }
    foreach ($key in $script:SettingsSections.Keys) {
        $entry = $script:SettingsSections[$key]
        $isActive = ($key -eq $Name)
        $entry.Panel.Visibility = if ($isActive) { 'Visible' } else { 'Collapsed' }
        $entry.Button.Background = if ($isActive) { $script:AccentTintBrush } else { $script:TransparentBrush }
        $entry.Button.BorderBrush = if ($isActive) { $script:AccentDeepBrush } else { $script:TransparentBrush }
        $entry.Button.FontWeight = if ($isActive) { 'SemiBold' } else { 'Normal' }
        Update-StepBadge -Name $key
    }
    $active = $script:SettingsSections[$Name]
    $SectionTitleText.Text = [string]$active.Title
    $SectionHintText.Text = [string]$active.Hint
}

$script:IsLoading = $true
$script:FfmpegPath = $null
$script:FfprobePath = $null
$script:SelectedEncoder = $null
# 24 rather than 30, chosen for throughput at this tool's real workload of
# thirty to fifty videos a day: it is a fifth fewer frames to render, worth
# roughly forty minutes a day.
#
# It is not free. A 24 FPS video on a 60 Hz screen cannot be shown evenly -
# 3:2 pulldown holds one frame for 50 ms and the next for 33 ms - and film
# hides that behind the motion blur of a 1/48 second shutter, which synthetic
# motion does not have. A slow zoom is where that shows most. 30 divides into
# 60 evenly and has none of it.
#
# What makes 24 defensible here is that 120 Hz displays, which is most recent
# phones, divide evenly by 24 as well and show it perfectly. The judder is a
# 60 Hz problem, and it is far milder than the whole-pixel stepping this
# renderer used to have, which was a different fault entirely and is fixed.
$script:DeliveryFps = 24
$script:RecommendedParallelSegments = $null
$script:VulkanDeviceIndex = $null
$script:FilterBackend = $null
$script:FilterVulkanDeviceIndex = $null
$script:EncoderBaseText = ''
$script:OpenClDevice = $null
$script:ScreenKernelPath = Join-Path $script:AppRoot 'Shaders\screen.cl'
$script:CurrentPlan = $null
$script:PlanSignature = $null
$script:PreviewFingerprint = $null
$script:PreviewValid = $false
$script:AudioDurationSeconds = 0.0
$script:CurrentProjectPath = $null
$script:FinalOutputPath = $null
$script:RenderProcess = $null
$script:RenderState = $null
$script:CancelRequested = $false
$script:CaptionPath = $null
$script:LiveCaptionEntries = @()
$script:LiveCaptionOverrideEntries = $null
$script:LiveCaptionCacheSignature = ''
$script:LastLiveCaptionText = ''
$script:IsApplyingCaptionPreset = $false
$script:PendingRenderAfterCaptions = $null
$script:LastHistoryProgressBucket = -1
$script:RenderHistoryPath = Join-Path $script:DataRoot 'render-history.json'
$script:RenderJobsRoot = Join-Path $script:DataRoot 'render-jobs'
$script:RenderHistory = @()
$script:IsFullScreen = $false
$script:OriginalWindowState = $window.WindowState
$script:OriginalWindowStyle = $window.WindowStyle
$script:OriginalSettingsWidth = $SettingsColumn.Width
$script:OriginalNavigationWidth = $NavigationColumn.Width

# The batch queue. It lives in the main window now, so it is kept on disk as
# well: closing the tool no longer throws away a morning of typed names.
$script:AppMode = 'Batch'
$script:SingleActiveSection = 'Media'
$script:QueueRows = [Collections.Generic.List[object]]::new()
$script:QueueStatePath = Join-Path $script:DataRoot 'queue.json'
$script:SelectedQueueRowId = ''
$script:ChannelFilter = '*'
$script:LastScanSkipped = @()
$script:BatchSettingsSection = ''
$script:QueuePreviewRowId = ''
$script:IsFillingInspector = $false
$script:ThumbnailRequests = [Collections.Generic.Queue[string]]::new()
$script:DurationProbe = $null
$script:PendingCaptionEditorAudio = ''
# The batch currently shown in place of the queue: its videos, and whether it
# is still running. Null while the queue itself is shown.
$script:BatchRun = $null
$script:NowRenderingThumb = $null
# Measured render speed, in seconds of video per second of rendering, per
# motion quality. Used to estimate how long a batch will take.
$script:RenderSpeeds = @{}

function Show-ErrorMessage {
    param([string]$Message, [string]$Title = 'Slideshow Video Tool')
    [System.Windows.MessageBox]::Show(
        $window,
        $Message,
        $Title,
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    ) | Out-Null
}

function Show-InfoMessage {
    param([string]$Message, [string]$Title = 'Slideshow Video Tool')
    [System.Windows.MessageBox]::Show(
        $window,
        $Message,
        $Title,
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Information
    ) | Out-Null
}

function Write-ToolDiagnostic {
    param(
        [string]$Message,
        [System.Exception]$Exception = $null
    )
    try {
        $details = "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] $Message"
        if ($null -ne $Exception) {
            $details += "`r`n$($Exception.ToString())"
        }
        $details += "`r`n"
        [IO.File]::AppendAllText($script:DiagnosticLogPath, $details, [Text.UTF8Encoding]::new($false))
    }
    catch {
        # Diagnostic logging must never terminate the UI.
    }
}

function Save-RenderHistory {
    try {
        $ordered = @($script:RenderHistory | Sort-Object StartedUtc -Descending | Select-Object -First 200)
        $script:RenderHistory = $ordered
        $json = if ($ordered.Count -eq 0) { '[]' } else { $ordered | ConvertTo-Json -Depth 8 }
        [IO.File]::WriteAllText($script:RenderHistoryPath, $json, [Text.UTF8Encoding]::new($false))
    }
    catch { Write-ToolDiagnostic 'Render history could not be saved.' $_.Exception }
}

function Load-RenderHistory {
    $script:RenderHistory = @()
    $historyNormalized = $false
    if (Test-Path -LiteralPath $script:RenderHistoryPath -PathType Leaf) {
        try {
            # Assign directly: wrapping ConvertFrom-Json in @() keeps JSON
            # arrays as one nested Object[] in Windows PowerShell 5.1.
            $loadedHistory = [IO.File]::ReadAllText($script:RenderHistoryPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $script:RenderHistory = @(
                foreach ($entry in $loadedHistory) {
                    if ($null -ne $entry.PSObject.Properties['Status']) {
                        $entry
                        continue
                    }

                    # Older saves can contain a PowerShell collection wrapper
                    # instead of the render jobs themselves. Preserve its jobs.
                    if ($null -ne $entry.PSObject.Properties['value']) {
                        foreach ($wrappedEntry in @($entry.value)) {
                            if ($null -ne $wrappedEntry.PSObject.Properties['Status']) {
                                $wrappedEntry
                            }
                        }
                    }
                    $historyNormalized = $true
                }
            )
        }
        catch { Write-ToolDiagnostic 'Render history could not be loaded.' $_.Exception }
    }
    $changed = $historyNormalized
    foreach ($entry in $script:RenderHistory) {
        if ([string]$entry.Status -eq 'Rendering') {
            $entry.Status = 'Paused'
            $entry.Detail = 'The application closed before this render finished.'
            $entry.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
            $changed = $true
        }
    }
    if ($changed) { Save-RenderHistory }
}

function Add-RenderHistoryEntry {
    param(
        [ValidateSet('Final','Batch')][string]$Type,
        [string]$Name,
        [string]$OutputPath,
        [string]$Encoder,
        [string]$ResumeDirectory = '',
        [string]$JobSnapshotPath = '',
        [string[]]$ProjectPaths = @()
    )
    $entry = [pscustomobject]@{
        Id = [guid]::NewGuid().ToString('N')
        Type = $Type
        Status = 'Rendering'
        Name = $Name
        OutputPath = $OutputPath
        ProjectPath = if ($script:CurrentProjectPath) { [string]$script:CurrentProjectPath } else { '' }
        ProjectPaths = @($ProjectPaths)
        Encoder = $Encoder
        Progress = 0
        ResumeDirectory = $ResumeDirectory
        JobSnapshotPath = $JobSnapshotPath
        StartedUtc = [DateTime]::UtcNow.ToString('o')
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        Detail = 'Rendering started.'
    }
    $script:RenderHistory = @($entry) + @($script:RenderHistory)
    Save-RenderHistory
    return $entry
}

function Update-RenderHistoryEntry {
    param([string]$Id, [string]$Status, [int]$Progress, [string]$Detail = '')
    if ([string]::IsNullOrWhiteSpace($Id)) { return }
    $entry = @($script:RenderHistory | Where-Object { [string]$_.Id -eq $Id } | Select-Object -First 1)
    if ($entry.Count -eq 0) { return }
    $item = $entry[0]
    if (-not [string]::IsNullOrWhiteSpace($Status)) { $item.Status = $Status }
    $item.Progress = [Math]::Max(0, [Math]::Min(100, $Progress))
    if (-not [string]::IsNullOrWhiteSpace($Detail)) { $item.Detail = $Detail }
    $item.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    Save-RenderHistory
}

function Get-ComboText {
    param([System.Windows.Controls.ComboBox]$ComboBox)
    if ($null -eq $ComboBox.SelectedItem) {
        return ''
    }
    return [string]$ComboBox.SelectedItem.Content
}

function Set-ComboText {
    param([System.Windows.Controls.ComboBox]$ComboBox, [string]$Text)
    foreach ($item in $ComboBox.Items) {
        if ([string]$item.Content -eq $Text) {
            $ComboBox.SelectedItem = $item
            return
        }
    }
}

function Update-CaptionPresetDescription {
    if ($null -eq $CaptionPresetCombo -or $null -eq $CaptionPresetHelpText) { return }
    $description = switch -Wildcard (Get-ComboText $CaptionPresetCombo) {
        '2.*'  { 'Left-aligned newsroom lower-third with a dark navy panel.' }
        '3.*'  { 'Minimal white text with a soft shadow and no box.' }
        '4.*'  { 'Centered white text on a compact translucent black box.' }
        '5.*'  { 'Bold yellow headline with a strong black outline.' }
        '6.*'  { 'Bright cyan accent text on a dark compact backing.' }
        '7.*'  { 'Warm documentary serif text on a charcoal band.' }
        '8.*'  { 'High-energy yellow emphasis with outline and shadow.' }
        '9.*'  { 'Captions placed in the upper safe area.' }
        '10.*' { 'Small left-aligned broadcast subtitle for maximum image visibility.' }
        default { 'White semibold text, centered safely above the bottom.' }
    }
    $CaptionPresetHelpText.Text = $description
}

function Get-CaptionPresetDefaults {
    param([string]$Preset)
    $base = [ordered]@{
        Font = 'Segoe UI Semibold'; Size = 16.0; Bold = $true
        Text = '#FFFFFF'; OutlineColor = '#000000'; Outline = 2.0; Shadow = 0.0
        Background = '#000000'; BackgroundOpacity = 0.0; Alignment = 'Center'
        X = 50.0; Y = 76.0; MaxWidth = 78.0; WordsPerLine = 8; LineSpacing = 1.0
    }
    switch -Wildcard ($Preset) {
        '1.*' { $base.Size=20;$base.Outline=3.5;$base.Y=78;$base.MaxWidth=78;$base.WordsPerLine=7 }
        '2.*' { $base.Font='Arial Narrow';$base.Size=20;$base.Background='#071525';$base.BackgroundOpacity=76;$base.Alignment='Left';$base.X=38;$base.Y=77;$base.MaxWidth=68;$base.Outline=1.5;$base.WordsPerLine=7 }
        '3.*' { $base.Font='Segoe UI';$base.Size=19;$base.Bold=$false;$base.Outline=0;$base.Shadow=2;$base.Y=76;$base.MaxWidth=76;$base.WordsPerLine=7 }
        '4.*' { $base.Size=19;$base.BackgroundOpacity=58;$base.Outline=1;$base.Y=76;$base.MaxWidth=72;$base.WordsPerLine=7 }
        '5.*' { $base.Size=20;$base.Text='#FFD400';$base.Outline=3.5;$base.Y=77;$base.MaxWidth=76;$base.WordsPerLine=7 }
        '6.*' { $base.Size=20;$base.Text='#22D3EE';$base.Outline=3.5;$base.Y=77;$base.MaxWidth=76;$base.WordsPerLine=7 }
        '7.*' { $base.Font='Georgia';$base.Size=20;$base.Text='#FFF4DC';$base.BackgroundOpacity=50;$base.Outline=1;$base.Shadow=1;$base.Y=78;$base.MaxWidth=88;$base.WordsPerLine=8;$base.LineSpacing=1.08 }
        '8.*' { $base.Size=20;$base.Text='#FFD400';$base.Outline=3.5;$base.Shadow=1;$base.Y=77;$base.MaxWidth=76;$base.WordsPerLine=7 }
        '9.*' { $base.Size=20;$base.BackgroundOpacity=48;$base.Outline=3;$base.Y=13;$base.MaxWidth=76;$base.WordsPerLine=7 }
        '10.*' { $base.Font='Arial';$base.Size=19;$base.Bold=$true;$base.Background='#05090E';$base.BackgroundOpacity=75;$base.Alignment='Left';$base.X=37;$base.Y=79;$base.MaxWidth=68;$base.Outline=1;$base.WordsPerLine=7 }
    }
    return [pscustomobject]$base
}

function Update-CaptionControlLabels {
    $CaptionSizeValueText.Text = ([double]$CaptionSizeSlider.Value).ToString('0.#')
    $CaptionOutlineValueText.Text = ([double]$CaptionOutlineSlider.Value).ToString('0.#')
    $CaptionShadowValueText.Text = ([double]$CaptionShadowSlider.Value).ToString('0.#')
    $CaptionBackgroundOpacityValueText.Text = "$([int][Math]::Round($CaptionBackgroundOpacitySlider.Value))%"
    $CaptionPositionXValueText.Text = "$([int][Math]::Round($CaptionPositionXSlider.Value))%"
    $CaptionPositionYValueText.Text = "$([int][Math]::Round($CaptionPositionYSlider.Value))%"
    $CaptionMaxWidthValueText.Text = "$([int][Math]::Round($CaptionMaxWidthSlider.Value))%"
    $CaptionWordsPerLineValueText.Text = [string][int][Math]::Round($CaptionWordsPerLineSlider.Value)
    $CaptionLineSpacingValueText.Text = ([double]$CaptionLineSpacingSlider.Value).ToString('0.00')
}

function Build-CaptionModeButtons {
    # Four buttons instead of a dropdown. The combo box behind them is still the
    # value everything else reads; these only move its selection, which is why
    # no other handler had to change.
    $labels = @('Off', 'File only', 'On video', 'Both')
    $CaptionModePanel.Children.Clear()
    for ($index = 0; $index -lt $labels.Count; $index++) {
        $button = [Windows.Controls.Button]::new()
        $button.Content = $labels[$index]
        $button.Style = $window.FindResource('TabButtonStyle')
        $button.Tag = $index
        $button.Add_Click({
            param($sender, $eventArgs)
            $CaptionModeCombo.SelectedIndex = [int]$sender.Tag
        }.GetNewClosure())
        [void]$CaptionModePanel.Children.Add($button)
    }
    Update-CaptionModeButtons
}

function Update-CaptionModeButtons {
    $selected = [int]$CaptionModeCombo.SelectedIndex
    foreach ($child in $CaptionModePanel.Children) {
        $isOn = ([int]$child.Tag -eq $selected)
        $child.Background = if ($isOn) { $script:AccentTintBrush } else { $script:TransparentBrush }
        $child.Foreground = if ($isOn) { $script:TextBrush } else { $script:MutedBrush }
        $child.FontWeight = if ($isOn) { 'SemiBold' } else { 'Normal' }
    }
}

function Build-CaptionPresetSwatches {
    # Each swatch is drawn from the preset's own values, so it shows the result
    # rather than a name. "1. Clean YouTube" through "10. Compact Broadcast"
    # told you nothing about what you were choosing between.
    $shortNames = @('Clean', 'News', 'Shadow', 'Box', 'Headline', 'Accent', 'Doc', 'Emphasis', 'Upper', 'Broadcast')
    $CaptionPresetSwatchPanel.Children.Clear()
    for ($index = 0; $index -lt $shortNames.Count; $index++) {
        $presetLabel = [string]$CaptionPresetCombo.Items[$index].Content
        $values = Get-CaptionPresetDefaults -Preset $presetLabel

        $sample = [Windows.Controls.TextBlock]::new()
        $sample.Text = 'Aa'
        $sample.FontFamily = [Windows.Media.FontFamily]::new([string]$values.Font)
        $sample.FontSize = 13
        $sample.FontWeight = if ($values.Bold) { 'Bold' } else { 'Normal' }
        $sample.Foreground = New-ToolBrush ([string]$values.Text)
        $sample.HorizontalAlignment = 'Center'
        $sample.Padding = [Windows.Thickness]::new(4, 0, 4, 0)
        if ([double]$values.BackgroundOpacity -gt 0) {
            $sample.Background = New-ToolBrush ([string]$values.Background)
            $sample.Opacity = 1.0
        }

        $caption = [Windows.Controls.TextBlock]::new()
        $caption.Text = $shortNames[$index]
        $caption.FontSize = 9
        $caption.Foreground = $script:MutedBrush
        $caption.HorizontalAlignment = 'Center'
        $caption.Margin = [Windows.Thickness]::new(0, 2, 0, 0)

        $stack = [Windows.Controls.StackPanel]::new()
        [void]$stack.Children.Add($sample)
        [void]$stack.Children.Add($caption)

        $button = [Windows.Controls.Button]::new()
        $button.Content = $stack
        $button.Height = 46
        $button.Margin = [Windows.Thickness]::new(0, 0, 5, 5)
        $button.Padding = [Windows.Thickness]::new(0)
        $button.Tag = $index
        $button.ToolTip = $presetLabel
        $button.Add_Click({
            param($sender, $eventArgs)
            $CaptionPresetCombo.SelectedIndex = [int]$sender.Tag
        }.GetNewClosure())
        [void]$CaptionPresetSwatchPanel.Children.Add($button)
    }
    Update-CaptionPresetSwatches
}

function Update-CaptionPresetSwatches {
    $selected = [int]$CaptionPresetCombo.SelectedIndex
    foreach ($child in $CaptionPresetSwatchPanel.Children) {
        $isOn = ([int]$child.Tag -eq $selected)
        $child.BorderBrush = if ($isOn) { $script:AccentBrush } else { (New-ToolBrush '#33333A') }
        $child.Background = if ($isOn) { $script:AccentTintBrush } else { (New-ToolBrush '#101012') }
    }
}

function Set-CaptionTab {
    # Font, colour and placement are three separate jobs. Showing all twenty
    # controls at once made the panel a scroll rather than a set of choices.
    param([string]$Name)
    $script:CaptionTab = $Name
    $tabs = @{
        'Type'     = @{ Button = $CaptionTabTypeButton;     Group = $CaptionGroupType }
        'Colour'   = @{ Button = $CaptionTabColourButton;   Group = $CaptionGroupColour }
        'Position' = @{ Button = $CaptionTabPositionButton; Group = $CaptionGroupPosition }
    }
    foreach ($key in $tabs.Keys) {
        $isOn = ($key -eq $Name)
        $tabs[$key].Group.Visibility = if ($isOn) { 'Visible' } else { 'Collapsed' }
        $tabs[$key].Button.Background = if ($isOn) { $script:AccentTintBrush } else { $script:TransparentBrush }
        $tabs[$key].Button.Foreground = if ($isOn) { $script:TextBrush } else { $script:MutedBrush }
        $tabs[$key].Button.FontWeight = if ($isOn) { 'SemiBold' } else { 'Normal' }
    }
}

function Apply-CaptionPresetToControls {
    param([string]$Preset)
    $values = Get-CaptionPresetDefaults -Preset $Preset
    $script:IsApplyingCaptionPreset = $true
    try {
        Set-ComboText $CaptionFontCombo $values.Font
        $CaptionSizeSlider.Value = $values.Size
        $CaptionBoldCheckBox.IsChecked = $values.Bold
        $CaptionTextColorText.Text = $values.Text
        $CaptionOutlineColorText.Text = $values.OutlineColor
        $CaptionOutlineSlider.Value = $values.Outline
        $CaptionShadowSlider.Value = $values.Shadow
        $CaptionBackgroundColorText.Text = $values.Background
        $CaptionBackgroundOpacitySlider.Value = $values.BackgroundOpacity
        Set-ComboText $CaptionAlignmentCombo $values.Alignment
        $CaptionPositionXSlider.Value = $values.X
        $CaptionPositionYSlider.Value = $values.Y
        $CaptionMaxWidthSlider.Value = $values.MaxWidth
        $CaptionWordsPerLineSlider.Value = $values.WordsPerLine
        $CaptionLineSpacingSlider.Value = $values.LineSpacing
    }
    finally { $script:IsApplyingCaptionPreset = $false }
    Update-CaptionControlLabels
    Apply-LiveCaptionStyle
}

function Get-UiSettings {
    $minimum = 0.0
    $maximum = 0.0
    $zoom = 0.0
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $style = [System.Globalization.NumberStyles]::Float

    if (-not [double]::TryParse($MinimumDurationText.Text.Trim(), $style, $culture, [ref]$minimum)) {
        throw 'Minimum duration must be a number such as 5.0.'
    }
    if (-not [double]::TryParse($MaximumDurationText.Text.Trim(), $style, $culture, [ref]$maximum)) {
        throw 'Maximum duration must be a number such as 7.0.'
    }
    if (-not [double]::TryParse($ZoomText.Text.Trim(), $style, $culture, [ref]$zoom)) {
        throw 'Maximum zoom must be a percentage such as 110.'
    }
    if ($minimum -lt 0.5 -or $maximum -gt 30.0 -or $minimum -gt $maximum) {
        throw 'Image durations must be between 0.5 and 30.0 seconds, with minimum not exceeding maximum.'
    }
    if ([Math]::Abs(($minimum * 10) - [Math]::Round($minimum * 10)) -gt 0.0001 -or
        [Math]::Abs(($maximum * 10) - [Math]::Round($maximum * 10)) -gt 0.0001) {
        throw 'Image durations must use 0.1-second increments.'
    }
    if ($zoom -lt 100 -or $zoom -gt 150) {
        throw 'Maximum zoom must be between 100% and 150%.'
    }
    $crossfade = [bool]$CrossfadeCheckBox.IsChecked
    $crossfadeSeconds = 0.0
    if ($crossfade) {
        if (-not [double]::TryParse($CrossfadeSecondsText.Text.Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$crossfadeSeconds)) {
            throw 'Dissolve length must be a number of seconds such as 0.5.'
        }
        if ($crossfadeSeconds -lt 0.1 -or $crossfadeSeconds -gt 2.0) {
            throw 'Dissolve length must be between 0.1 and 2.0 seconds.'
        }
    }
    foreach ($colorControl in @($CaptionTextColorText, $CaptionOutlineColorText, $CaptionBackgroundColorText)) {
        if ($colorControl.Text.Trim() -notmatch '^#[0-9A-Fa-f]{6}$') {
            throw 'Caption colors must use six-digit hex values such as #FFFFFF or #000000.'
        }
    }

    return [pscustomobject]@{
        MinimumDuration = $minimum
        MaximumDuration = $maximum
        ZoomMaximum = $zoom
        MotionQuality = Get-ComboText $MotionQualityCombo
        Crossfade = $crossfade
        CrossfadeSeconds = $crossfadeSeconds
        BlurAmount = [double]$BlurSlider.Value
        BackgroundBrightness = [double]$BrightnessSlider.Value
        Quality = Get-ComboText $QualityCombo
        CaptionMode = Get-ComboText $CaptionModeCombo
        CaptionPreset = Get-ComboText $CaptionPresetCombo
        CaptionFont = Get-ComboText $CaptionFontCombo
        CaptionFontSize = [double]$CaptionSizeSlider.Value
        CaptionBold = [bool]$CaptionBoldCheckBox.IsChecked
        CaptionTextColor = Get-EffectiveCaptionTextColor -TextColor $CaptionTextColorText.Text.Trim() -BackgroundColor $CaptionBackgroundColorText.Text.Trim() -BackgroundOpacity ([double]$CaptionBackgroundOpacitySlider.Value)
        CaptionOutlineColor = $CaptionOutlineColorText.Text.Trim()
        CaptionOutlineWidth = [double]$CaptionOutlineSlider.Value
        CaptionShadow = [double]$CaptionShadowSlider.Value
        CaptionBackgroundColor = $CaptionBackgroundColorText.Text.Trim()
        CaptionBackgroundOpacity = [double]$CaptionBackgroundOpacitySlider.Value
        CaptionAlignment = Get-ComboText $CaptionAlignmentCombo
        CaptionPositionX = [double]$CaptionPositionXSlider.Value
        CaptionPositionY = [double]$CaptionPositionYSlider.Value
        CaptionMaxWidth = [double]$CaptionMaxWidthSlider.Value
        CaptionWordsPerLine = [int][Math]::Round($CaptionWordsPerLineSlider.Value)
        CaptionLineSpacing = [double]$CaptionLineSpacingSlider.Value
        Volume = [double]$VolumeSlider.Value
    }
}

function Save-UserSettings {
    try {
        $settings = Get-UiSettings
        $settings | Add-Member -NotePropertyName LastImageFolder -NotePropertyValue $ImageFolderText.Text
        $settings | Add-Member -NotePropertyName LastAudioPath -NotePropertyValue $AudioText.Text
        $settings | Add-Member -NotePropertyName LastWatermarkPath -NotePropertyValue $WatermarkText.Text
        $settings | Add-Member -NotePropertyName LastChannelsRoot -NotePropertyValue $script:LastChannelsRoot
        $settings | Add-Member -NotePropertyName LastBatchWatermarkPath -NotePropertyValue $BatchWatermarkText.Text
        $settings | Add-Member -NotePropertyName RenderSpeeds -NotePropertyValue ([pscustomobject]$script:RenderSpeeds)
        $json = $settings | ConvertTo-Json -Depth 4
        [IO.File]::WriteAllText($script:SettingsPath, $json, [Text.UTF8Encoding]::new($false))
    }
    catch {
        # Invalid in-progress text should not prevent the application from closing.
    }
}

function Load-UserSettings {
    if (-not (Test-Path -LiteralPath $script:SettingsPath -PathType Leaf)) {
        return
    }
    try {
        $settings = [IO.File]::ReadAllText($script:SettingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($null -ne $settings.MinimumDuration) { $MinimumDurationText.Text = [string]$settings.MinimumDuration }
        if ($null -ne $settings.MaximumDuration) { $MaximumDurationText.Text = [string]$settings.MaximumDuration }
        if ($null -ne $settings.ZoomMaximum) { $ZoomText.Text = [string]$settings.ZoomMaximum }
        if ($null -ne $settings.PSObject.Properties['MotionQuality']) { Set-ComboText $MotionQualityCombo ([string]$settings.MotionQuality) }
        if ($null -ne $settings.PSObject.Properties['Crossfade']) { $CrossfadeCheckBox.IsChecked = [bool]$settings.Crossfade }
        if ($null -ne $settings.PSObject.Properties['CrossfadeSeconds'] -and [double]$settings.CrossfadeSeconds -gt 0) { $CrossfadeSecondsText.Text = [string]$settings.CrossfadeSeconds }
        if ($null -ne $settings.BlurAmount) { $BlurSlider.Value = [double]$settings.BlurAmount }
        if ($null -ne $settings.BackgroundBrightness) { $BrightnessSlider.Value = [double]$settings.BackgroundBrightness }
        if ($null -ne $settings.Quality) { Set-ComboText $QualityCombo ([string]$settings.Quality) }
        if ($null -ne $settings.PSObject.Properties['CaptionMode']) { Set-ComboText $CaptionModeCombo ([string]$settings.CaptionMode) }
        if ($null -ne $settings.PSObject.Properties['CaptionPreset']) { Set-ComboText $CaptionPresetCombo ([string]$settings.CaptionPreset) }
        if ($null -ne $settings.PSObject.Properties['CaptionFont']) {
            Set-ComboText $CaptionFontCombo ([string]$settings.CaptionFont)
            $CaptionSizeSlider.Value = [double]$settings.CaptionFontSize
            $CaptionBoldCheckBox.IsChecked = [bool]$settings.CaptionBold
            $CaptionTextColorText.Text = [string]$settings.CaptionTextColor
            $CaptionOutlineColorText.Text = [string]$settings.CaptionOutlineColor
            $CaptionOutlineSlider.Value = [double]$settings.CaptionOutlineWidth
            $CaptionShadowSlider.Value = [double]$settings.CaptionShadow
            $CaptionBackgroundColorText.Text = [string]$settings.CaptionBackgroundColor
            $CaptionBackgroundOpacitySlider.Value = [double]$settings.CaptionBackgroundOpacity
            Set-ComboText $CaptionAlignmentCombo ([string]$settings.CaptionAlignment)
            $CaptionPositionXSlider.Value = [double]$settings.CaptionPositionX
            $CaptionPositionYSlider.Value = [double]$settings.CaptionPositionY
            $CaptionMaxWidthSlider.Value = [double]$settings.CaptionMaxWidth
            if ($settings.PSObject.Properties['CaptionWordsPerLine']) { $CaptionWordsPerLineSlider.Value = [double]$settings.CaptionWordsPerLine }
            $CaptionLineSpacingSlider.Value = [double]$settings.CaptionLineSpacing
            if (-not $settings.PSObject.Properties['CaptionWordsPerLine']) {
                # First launch after the reference-caption update: migrate the
                # old preset values to the new reference-matched defaults.
                Apply-CaptionPresetToControls (Get-ComboText $CaptionPresetCombo)
            }
        }
        else { Apply-CaptionPresetToControls (Get-ComboText $CaptionPresetCombo) }
        if ($null -ne $settings.Volume) { $VolumeSlider.Value = [double]$settings.Volume }
        if ($null -ne $settings.LastImageFolder) { $ImageFolderText.Text = [string]$settings.LastImageFolder }
        if ($null -ne $settings.LastAudioPath) { $AudioText.Text = [string]$settings.LastAudioPath }
        if ($null -ne $settings.LastWatermarkPath) { $WatermarkText.Text = [string]$settings.LastWatermarkPath }
        if ($null -ne $settings.PSObject.Properties['LastChannelsRoot']) { $script:LastChannelsRoot = [string]$settings.LastChannelsRoot }
        if ($null -ne $settings.PSObject.Properties['LastBatchWatermarkPath']) { $BatchWatermarkText.Text = [string]$settings.LastBatchWatermarkPath }
        elseif ($null -ne $settings.LastWatermarkPath) { $BatchWatermarkText.Text = [string]$settings.LastWatermarkPath }
        if ($null -ne $settings.PSObject.Properties['RenderSpeeds'] -and $null -ne $settings.RenderSpeeds) {
            foreach ($property in $settings.RenderSpeeds.PSObject.Properties) {
                $speed = 0.0
                if ([double]::TryParse([string]$property.Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$speed) -and $speed -gt 0) {
                    $script:RenderSpeeds[[string]$property.Name] = $speed
                }
            }
        }
    }
    catch {
        $StatusText.Text = 'Saved settings could not be loaded; defaults are being used.'
    }
}

function Get-CaptionEngineRoot {
    # The speech engine and its models are about 535 MB, so by default they are
    # downloaded once into the per-user data folder rather than shipped. Copying
    # that folder into Tools\caption-engine makes it travel with the tool, which
    # lets a new computer generate captions without downloading anything.
    $portableRoot = Join-Path $script:AppRoot 'Tools\caption-engine'
    if (Test-Path -LiteralPath $portableRoot -PathType Container) {
        return $portableRoot
    }
    return (Join-Path $script:DataRoot 'caption-engine')
}

function Find-FFmpegTools {
    # FFmpeg 8.x requires NVENC API 13.1, which the final Pascal/Quadro P620
    # driver branch cannot provide. Prefer the bundled 7.1.1 runtime whose
    # older NVENC API is compatible with this GPU and driver.
    $bundledBin = Join-Path $script:AppRoot 'Tools\FFmpeg-7.1.1\ffmpeg-7.1.1-full_build\bin'
    $bundledFfmpeg = Join-Path $bundledBin 'ffmpeg.exe'
    $bundledFfprobe = Join-Path $bundledBin 'ffprobe.exe'
    if ((Test-Path -LiteralPath $bundledFfmpeg -PathType Leaf) -and (Test-Path -LiteralPath $bundledFfprobe -PathType Leaf)) {
        $script:FfmpegPath = $bundledFfmpeg
        $script:FfprobePath = $bundledFfprobe
        $EncoderText.Text = 'Compatible FFmpeg 7.1.1 ready'
        return $true
    }

    $ffmpegCommand = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    $ffprobeCommand = Get-Command ffprobe.exe -ErrorAction SilentlyContinue
    if ($null -ne $ffmpegCommand -and $null -ne $ffprobeCommand) {
        $script:FfmpegPath = $ffmpegCommand.Source
        $script:FfprobePath = $ffprobeCommand.Source
        $EncoderText.Text = 'FFmpeg ready - encoder checked at render time'
        return $true
    }

    # WinGet updates PATH for newly opened processes, but occasionally the
    # command alias is unavailable even after installation. Locate the package
    # directly so the portable tool remains usable in that situation.
    $packageRoots = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'),
        'C:\Program Files\WinGet\Packages'
    )
    foreach ($packageRoot in $packageRoots) {
        if (-not (Test-Path -LiteralPath $packageRoot -PathType Container)) {
            continue
        }
        $packages = @(
            Get-ChildItem -LiteralPath $packageRoot -Directory -Filter 'Gyan.FFmpeg*' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTimeUtc -Descending
        )
        foreach ($package in $packages) {
            $candidate = Get-ChildItem -LiteralPath $package.FullName -Filter ffmpeg.exe -File -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($null -ne $candidate) {
                $candidateProbe = Join-Path $candidate.DirectoryName 'ffprobe.exe'
                if (Test-Path -LiteralPath $candidateProbe -PathType Leaf) {
                    $script:FfmpegPath = $candidate.FullName
                    $script:FfprobePath = $candidateProbe
                    $EncoderText.Text = 'FFmpeg ready - encoder checked at render time'
                    return $true
                }
            }
        }
    }

    $script:FfmpegPath = $null
    $script:FfprobePath = $null
    $EncoderText.Text = 'FFmpeg not installed'
    $StatusText.Text = 'FFmpeg is required. Click Generate Preview to see the installation command.'
    return $false
}

function Assert-FFmpegAvailable {
    if (Find-FFmpegTools) {
        return
    }
    throw @'
FFmpeg is not installed or is not available on PATH.

Open PowerShell and run:

winget install --exact --id Gyan.FFmpeg --accept-package-agreements --accept-source-agreements

Then close and reopen this tool.
'@
}

function Test-VideoEncoder {
    param([string]$Encoder)
    # Probe at the resolution this tool actually delivers, not at a token
    # thumbnail. Hardware encoders refuse frames below a minimum size, and that
    # minimum grew: NVENC on Pascal accepted a width of 33, but Turing raised it
    # to 145 and every card since has kept it. A 64x64 probe therefore reported
    # "no NVENC" on every modern NVIDIA GPU, and the tool fell through to Quick
    # Sync on the integrated chip - or to libx264 on a desktop that has no
    # integrated chip at all - while the discrete card sat idle. 1920x1080 is
    # one frame of black and costs nothing to encode, and answers the only
    # question being asked: can this encoder handle the real output?
    $arguments = @(
        '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'color=c=black:s=1920x1080:r=24',
        '-frames:v', '1', '-c:v', $Encoder, '-f', 'null', 'NUL'
    )

    # Invoke the probe through ProcessStartInfo instead of PowerShell's native
    # command pipeline. With ErrorActionPreference=Stop, some PowerShell builds
    # turn an expected FFmpeg encoder-probe failure into a terminating error,
    # preventing the intended NVENC -> QSV -> CPU fallback.
    $process = $null
    try {
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $script:FfmpegPath
        $startInfo.Arguments = Join-ProcessArguments $arguments
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true

        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            return $false
        }

        # The probe creates one 64x64 frame, so both streams remain tiny.
        [void]$process.StandardOutput.ReadToEnd()
        [void]$process.StandardError.ReadToEnd()
        $process.WaitForExit()
        return ($process.ExitCode -eq 0)
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Find-NvidiaVulkanEncoderDevice {
    # Device order is normally Intel=0, NVIDIA=1 on this laptop, but probe a
    # small range so the tool remains usable if Windows changes that order.
    #
    # Delivery resolution for the same reason as Test-VideoEncoder: this is a
    # hardware encoder, and hardware encoders reject frames below a minimum
    # size that a thumbnail-sized probe sits underneath.
    $fallbackIndex = $null
    foreach ($deviceIndex in @(1, 0, 2, 3)) {
        $arguments = @(
            '-hide_banner', '-loglevel', 'info',
            '-init_hw_device', "vulkan=slideshowgpu:$deviceIndex",
            '-filter_hw_device', 'slideshowgpu',
            '-f', 'lavfi', '-i', 'color=c=black:s=1920x1080:r=24',
            '-vf', 'format=nv12,hwupload',
            '-frames:v', '1', '-c:v', 'h264_vulkan', '-f', 'null', 'NUL'
        )

        $process = $null
        try {
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $script:FfmpegPath
            $startInfo.Arguments = Join-ProcessArguments $arguments
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true

            $process = [Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            if (-not $process.Start()) {
                continue
            }
            [void]$process.StandardOutput.ReadToEnd()
            $errorText = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            if ($process.ExitCode -eq 0) {
                if ($errorText -match '(?i)nvidia|quadro') {
                    return $deviceIndex
                }
                if ($null -eq $fallbackIndex) {
                    $fallbackIndex = $deviceIndex
                }
            }
        }
        catch {}
        finally {
            if ($null -ne $process) {
                $process.Dispose()
            }
        }
    }
    return $fallbackIndex
}

function Find-NvidiaOpenClDevice {
    # NVIDIA is normally OpenCL 1.0 on this dual-GPU laptop. Probe instead of
    # hard-coding it so the portable application also survives device reorder.
    $fallbackDevice = $null
    foreach ($device in @('1.0', '0.0', '2.0', '0.1')) {
        $arguments = @(
            '-hide_banner', '-loglevel', 'info',
            '-init_hw_device', "opencl=screencl:$device",
            '-filter_hw_device', 'screencl',
            '-f', 'lavfi', '-i', 'color=c=black:s=64x64:r=1',
            '-vf', 'format=rgba,hwupload,hwdownload,format=rgba',
            '-frames:v', '1', '-f', 'null', 'NUL'
        )
        $process = $null
        try {
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $script:FfmpegPath
            $startInfo.Arguments = Join-ProcessArguments $arguments
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $process = [Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            if (-not $process.Start()) { continue }
            [void]$process.StandardOutput.ReadToEnd()
            $errorText = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            if ($process.ExitCode -eq 0) {
                if ($errorText -match '(?i)nvidia|quadro') { return $device }
                if ($null -eq $fallbackDevice) { $fallbackDevice = $device }
            }
        }
        catch {}
        finally { if ($null -ne $process) { $process.Dispose() } }
    }
    return $fallbackDevice
}

function Test-SimultaneousEncoderSessions {
    # Hardware encoders cap how many encodes may be open at once and refuse the
    # extras outright rather than queueing them. GeForce drivers have allowed
    # anywhere from two to eight NVENC sessions depending on their age, and AMF
    # and Quick Sync have their own ceilings, so the only portable way to learn
    # the limit on a given machine is to try it.
    param([string]$Encoder, [int]$Count)
    if ($Count -le 1) { return $true }

    $processes = [Collections.Generic.List[object]]::new()
    try {
        for ($index = 0; $index -lt $Count; $index++) {
            # 48 frames is long enough that the probes genuinely overlap; a
            # single frame can finish before the next process has even started,
            # which would make any limit look higher than it is.
            $arguments = @(
                '-hide_banner', '-loglevel', 'error',
                '-f', 'lavfi', '-i', 'color=c=black:s=1280x720:r=24',
                '-frames:v', '48', '-c:v', $Encoder, '-f', 'null', 'NUL'
            )
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $script:FfmpegPath
            $startInfo.Arguments = Join-ProcessArguments $arguments
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $process = [Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            if (-not $process.Start()) { return $false }
            $null = $process.Handle
            $processes.Add($process)
        }
        foreach ($process in $processes) {
            [void]$process.StandardOutput.ReadToEnd()
            [void]$process.StandardError.ReadToEnd()
            $process.WaitForExit()
            if ($process.ExitCode -ne 0) { return $false }
        }
        return $true
    }
    catch {
        return $false
    }
    finally {
        foreach ($process in $processes) {
            try { if (-not $process.HasExited) { $process.Kill() } } catch {}
            try { $process.Dispose() } catch {}
        }
    }
}

function Get-RecommendedParallelSegments {
    # How many segments render at once. Each lane runs its own FFmpeg process
    # that scales photographs onto a 2x overscan canvas, so a lane costs both a
    # core and a couple of gigabytes. Deciding this per machine keeps the tool
    # portable: a four-core laptop must not launch the same number of lanes as
    # a workstation, or it thrashes and finishes slower than a single lane.
    param([string]$Encoder = '')

    if ($null -ne $script:RecommendedParallelSegments) {
        return $script:RecommendedParallelSegments
    }

    $logicalCores = [Environment]::ProcessorCount
    if ($logicalCores -lt 1) { $logicalCores = 1 }
    # A lane no longer costs one saturated core. zoompan could not be threaded,
    # so lanes were the only way to use a machine; the sub-pixel warp that
    # replaced it threads across cores by itself, which means the lanes now
    # compete for the same cores rather than filling idle ones.
    #
    # Measured on a 30-second segment of six photographs, eight logical cores:
    # 3 lanes 2.13x realtime, 4 lanes 2.19x, 6 lanes 2.13x, 8 lanes 2.30x,
    # 10 lanes 2.17x. It is a plateau, not a peak - anything from three lanes
    # up lands within eight percent - so this picks the middle of it and does
    # not chase the last few percent.
    $byCpu = [int][Math]::Floor($logicalCores / 2.0)

    # Assume a modest machine when the memory query is unavailable.
    $totalGb = 8.0
    try {
        $bytes = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
        if ($bytes -gt 0) { $totalGb = [double]$bytes / 1GB }
    }
    catch {}
    # Measured rather than estimated: one lane rendering a 30 second segment
    # peaked at just over 1.5 GB when the renderer built every frame on a
    # 3840x2160 canvas. That canvas is gone - the motion filter now warps
    # straight onto the delivery frame - and peak working set fell with it,
    # from 730 MB to 191 MB on the same measurement. 0.8 covers the new figure
    # with the same margin the old number had.
    #
    # The five gigabytes held back are for Windows, this tool, and whatever the
    # person is doing while they wait. Reserving less looked affordable on a
    # machine with nothing else running and would have put an eight gigabyte
    # laptop into swap, which costs far more than the extra lane wins.
    $byMemory = [int][Math]::Floor(($totalGb - 5.0) / 0.8)

    $lanes = [Math]::Min($byCpu, $byMemory)
    if ($lanes -lt 1) { $lanes = 1 }
    # Eight measured best on the sweep above, and it is where the plateau is
    # widest. Past that the lanes contend for the same cores instead of adding
    # any: ten lanes came in below eight.
    if ($lanes -gt 8) { $lanes = 8 }

    # Step down to a lane count the encoder will actually grant. Discovering
    # this here costs a few seconds once; discovering it mid-render costs a
    # part-finished segment for every step down.
    if (-not [string]::IsNullOrWhiteSpace($Encoder) -and $Encoder -ne 'libx264' -and $lanes -gt 1) {
        $StatusText.Text = "Checking how many renders this graphics card allows at once..."
        $window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
        while ($lanes -gt 1 -and -not (Test-SimultaneousEncoderSessions -Encoder $Encoder -Count $lanes)) {
            $lanes--
        }
    }

    $script:RecommendedParallelSegments = $lanes
    return $lanes
}

function Select-AvailableEncoder {
    if ($null -ne $script:SelectedEncoder) {
        return $script:SelectedEncoder
    }

    $StatusText.Text = 'Checking compatible NVIDIA NVENC and GPU effects...'
    $window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
    if ((Test-VideoEncoder 'h264_nvenc')) {
        # The OpenCL compositor is deliberately left switched off. Compositing
        # the watermark on the GPU repeats frames: rendering the same timeline
        # twice, changing nothing but the compositor, gave 0 repeated frames out
        # of 382 through the CPU blend and 103 through OpenCL, dropping the
        # motion from a true 24 FPS to about 17. On a slow pan that reads as
        # juddering and dragging. Aligning the timestamps of the two OpenCL
        # inputs recovered only 8 of those frames, so the fault is not simply a
        # mismatch this code can correct.
        #
        # Only the watermark and caption compositing moved to the GPU, and that
        # stage was never the slow part, so the cost of doing it on the CPU is
        # small next to producing a video that actually animates smoothly.
        $script:OpenClDevice = $null
        $script:SelectedEncoder = 'h264_nvenc'
        $EncoderText.Text = 'NVIDIA NVENC hardware encoding'
        return $script:SelectedEncoder
    }

    # AMD is probed before Vulkan because AMF is the mature encoder on Radeon,
    # while Vulkan H.264 encoding depends on very recent drivers.
    $StatusText.Text = 'NVENC unavailable; checking AMD AMF...'
    $window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
    if (Test-VideoEncoder 'h264_amf') {
        $script:SelectedEncoder = 'h264_amf'
        $EncoderText.Text = 'AMD AMF hardware encoding'
        return $script:SelectedEncoder
    }

    $StatusText.Text = 'NVENC unavailable; checking NVIDIA Vulkan...'
    $window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
    $vulkanDevice = Find-NvidiaVulkanEncoderDevice
    if ($null -ne $vulkanDevice) {
        $script:VulkanDeviceIndex = [int]$vulkanDevice
        $script:SelectedEncoder = 'h264_vulkan'
        $EncoderText.Text = 'NVIDIA GPU - Vulkan H.264 fallback'
        return $script:SelectedEncoder
    }

    $StatusText.Text = 'NVENC unavailable; checking Intel Quick Sync...'
    $window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
    if (Test-VideoEncoder 'h264_qsv') {
        $script:SelectedEncoder = 'h264_qsv'
        $EncoderText.Text = 'Intel Quick Sync fallback'
        return $script:SelectedEncoder
    }

    $script:SelectedEncoder = 'libx264'
    $EncoderText.Text = 'CPU encoding fallback - slower'
    return $script:SelectedEncoder
}

function Set-FilterBackendDisplay {
    $base = if ([string]::IsNullOrWhiteSpace($script:EncoderBaseText)) { [string]$EncoderText.Text } else { $script:EncoderBaseText }
    if ($script:FilterBackend -eq 'vulkan') {
        $EncoderText.Text = "$base + GPU motion effects"
    }
    else {
        $EncoderText.Text = "$base + CPU motion effects"
    }
}

function Set-CpuFilterFallback {
    # Reached when a render using the Vulkan encoder's filter graph reports a
    # device failure. Ordinary renders already filter on the processor.
    $script:FilterBackend = 'cpu'
    $script:FilterVulkanDeviceIndex = $null
    Set-FilterBackendDisplay
}

function Select-AvailableFilterBackend {
    # Motion effects run on the processor. There is a Vulkan/libplacebo graph
    # in the engine and it is genuinely faster, but it does not reproduce
    # itself: rendering one 30-second segment repeatedly from identical inputs
    # on an RTX A4000 produced different videos, differing by 14 to 19 dB -
    # whole clips landing on the wrong photograph, some of them nearly black.
    # The processor graph rendered the same segment identically every time.
    #
    # It was chosen once and rejected before, so this is not new; what changed
    # is that the tool started reaching it. It stayed unreachable for a
    # different reason than anyone thought, and one delivered 21-minute video
    # is what it cost to find out.
    #
    # Re-tested since, because part of the original diagnosis was wrong. The
    # graph did carry a real bug: the loop filter hands out copies of one
    # uploaded frame, every copy keeps that frame's timestamp, and the crop was
    # driven by time, so the motion never advanced. That is fixed, and the fixed
    # graph is the better renderer on paper - 0.3 percent frame-to-frame motion
    # variance against the processor's 0.9, sharper, and faster.
    #
    # It still does not reproduce itself. Rendering one 30-second segment five
    # times and comparing the decoded frames gave four different videos, each
    # 896 frames instead of 900. Frames are being dropped, and only while an
    # encoder is consuming the output: hashing the frames straight out of the
    # filter graph, with no encoder behind it, the same five runs matched
    # exactly. It is a race against back-pressure, not a bad crop, which is why
    # it hides in every cheap test and appears in real renders.
    #
    # It is also no longer worth the risk. That graph earned its place when
    # every frame was generated twice for shutter blur; with that gone it
    # measured 33.7 seconds against the processor's 34.3 on the same
    # photographs and lane count - two percent - so this trades nothing for a
    # video that is right every time.
    #
    # Vulkan's own H.264 encoder is the one exception. It only accepts frames
    # that are already on the graphics card, so it has no processor path to
    # fall back to, and it is itself only reached when NVENC, AMF and Quick
    # Sync have all been ruled out.
    param(
        [Parameter(Mandatory = $true)][psobject]$Timeline,
        [Parameter(Mandatory = $true)][psobject]$Settings,
        [Parameter(Mandatory = $true)][string]$WatermarkPath
    )
    if ($null -ne $script:FilterBackend) {
        return $script:FilterBackend
    }

    $script:EncoderBaseText = [string]$EncoderText.Text
    if ($script:SelectedEncoder -eq 'h264_vulkan') {
        $script:FilterBackend = 'vulkan'
        $script:FilterVulkanDeviceIndex = [int]$script:VulkanDeviceIndex
        Set-FilterBackendDisplay
        Write-ToolDiagnostic "Filter backend selected. Backend=vulkan VulkanDevice=$($script:FilterVulkanDeviceIndex) (required by the Vulkan encoder)"
        return $script:FilterBackend
    }

    $script:FilterBackend = 'cpu'
    $script:FilterVulkanDeviceIndex = $null
    Set-FilterBackendDisplay
    Write-ToolDiagnostic 'Filter backend selected. Backend=cpu'
    return $script:FilterBackend
}

function Invalidate-Preview {
    param([bool]$ResetPlan = $false)
    if ($script:IsLoading) {
        return
    }
    if ($ResetPlan) {
        $script:CurrentPlan = $null
        $script:PlanSignature = $null
        if ($null -ne $StoryboardPanel) {
            $StoryboardPanel.Children.Clear()
            $StoryboardSummaryText.Text = '  Generate a preview to build the randomized timeline'
        }
    }
    if ($script:PreviewValid) {
        $StatusText.Text = 'Settings changed. Generate a new preview before final rendering.'
    }
    $script:PreviewValid = $false
    $script:PreviewFingerprint = $null
    $FinalButton.IsEnabled = $false
}

function Update-StoryboardUI {
    if ($null -eq $StoryboardPanel) { return }
    $StoryboardPanel.Children.Clear()
    if ($null -eq $script:CurrentPlan -or @($script:CurrentPlan.Items).Count -eq 0) {
        $StoryboardSummaryText.Text = '  Generate a preview to build the randomized timeline'
        return
    }

    $items = @($script:CurrentPlan.Items)
    $durationText = Format-PlayerTime ([TimeSpan]::FromSeconds([double]$script:CurrentPlan.AudioDurationSeconds))
    $StoryboardSummaryText.Text = "  $($items.Count) scenes  |  $durationText total"
    $visibleCount = [Math]::Min(10, $items.Count)
    for ($index = 0; $index -lt $visibleCount; $index++) {
        $item = $items[$index]
        if ($index -gt 0) {
            $arrow = [Windows.Controls.TextBlock]::new()
            $arrow.Text = '>'
            $arrow.Foreground = [Windows.Media.Brushes]::MediumPurple
            $arrow.FontSize = 18
            $arrow.FontWeight = [Windows.FontWeights]::Bold
            $arrow.Margin = [Windows.Thickness]::new(3, 0, 3, 20)
            $arrow.VerticalAlignment = [Windows.VerticalAlignment]::Center
            [void]$StoryboardPanel.Children.Add($arrow)
        }

        $card = [Windows.Controls.Border]::new()
        $card.Width = 112
        $card.Height = 102
        $card.Margin = [Windows.Thickness]::new(2, 1, 2, 2)
        $card.Padding = [Windows.Thickness]::new(4)
        $card.CornerRadius = [Windows.CornerRadius]::new(7)
        $card.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#171E2B')
        $card.BorderBrush = if ($index -eq 0) { [Windows.Media.BrushConverter]::new().ConvertFromString('#8B5CF6') } else { [Windows.Media.BrushConverter]::new().ConvertFromString('#344057') }
        $card.BorderThickness = [Windows.Thickness]::new(1)

        $stack = [Windows.Controls.StackPanel]::new()
        $thumbnail = [Windows.Controls.Image]::new()
        $thumbnail.Width = 102
        $thumbnail.Height = 62
        $thumbnail.Stretch = [Windows.Media.Stretch]::UniformToFill
        try {
            $bitmap = [Windows.Media.Imaging.BitmapImage]::new()
            $bitmap.BeginInit()
            $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bitmap.UriSource = [uri]([string]$item.ImagePath)
            $bitmap.EndInit()
            $bitmap.Freeze()
            $thumbnail.Source = $bitmap
        }
        catch {}
        [void]$stack.Children.Add($thumbnail)

        $seconds = [int]$item.Frames / [double]$script:CurrentPlan.Fps
        $detail = [Windows.Controls.TextBlock]::new()
        $panText = if ($item.PSObject.Properties['PanDirection']) { [string]$item.PanDirection } else { 'None' }
        $motionText = if ($panText -eq 'None') { [string]$item.ZoomDirection } else { "$($item.ZoomDirection) | Pan $panText" }
        $detail.Text = "$($seconds.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture))s  $motionText"
        $detail.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#AEB8C9')
        $detail.FontSize = 10
        $detail.Margin = [Windows.Thickness]::new(2, 5, 0, 0)
        [void]$stack.Children.Add($detail)
        $card.Child = $stack
        [void]$StoryboardPanel.Children.Add($card)
    }
    if ($items.Count -gt $visibleCount) {
        $more = [Windows.Controls.TextBlock]::new()
        $more.Text = "+$($items.Count - $visibleCount) more"
        $more.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#8490A5')
        $more.Margin = [Windows.Thickness]::new(10, 0, 8, 20)
        $more.VerticalAlignment = [Windows.VerticalAlignment]::Center
        [void]$StoryboardPanel.Children.Add($more)
    }
}

function Update-SettingLabels {
    $BlurValueText.Text = [string][int]$BlurSlider.Value
    $BrightnessValueText.Text = "$([int]$BrightnessSlider.Value)%"
}

function Format-Clock {
    param([double]$Seconds)
    if ($Seconds -le 0) { return '' }
    $span = [TimeSpan]::FromSeconds([Math]::Round($Seconds))
    if ($span.TotalHours -ge 1) { return ('{0}:{1:00}:{2:00}' -f [int]$span.TotalHours, $span.Minutes, $span.Seconds) }
    return ('{0}:{1:00}' -f [int]$span.TotalMinutes, $span.Seconds)
}

function Format-ByteSize {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

function Get-SourceSummaries {
    # Reports what is actually behind each chosen path. Three text boxes holding
    # three paths told nobody whether the folder had four photographs or four
    # hundred, and that only surfaced at render time.
    $result = [ordered]@{
        ImageCount = 0
        ImageText = 'No folder chosen'
        AudioText = 'No voiceover chosen'
        AudioReady = $false
        WatermarkText = 'No overlay chosen'
        WatermarkReady = $false
    }

    $folder = [string]$ImageFolderText.Text
    if (-not [string]::IsNullOrWhiteSpace($folder)) {
        if (Test-Path -LiteralPath $folder -PathType Container) {
            try {
                $files = @(Get-SupportedImageFiles -Folder $folder)
                $result.ImageCount = $files.Count
                if ($files.Count -eq 0) {
                    $result.ImageText = 'No usable photographs in this folder'
                }
                else {
                    $bytes = 0.0
                    $extensions = [Collections.Generic.HashSet[string]]::new()
                    foreach ($file in $files) {
                        try {
                            $item = Get-Item -LiteralPath $file -ErrorAction Stop
                            $bytes += [double]$item.Length
                            [void]$extensions.Add($item.Extension.TrimStart('.').ToUpperInvariant())
                        }
                        catch {}
                    }
                    $kinds = (@($extensions) | Sort-Object) -join ', '
                    $result.ImageText = "$($files.Count) photographs, $(Format-ByteSize $bytes), $kinds"
                }
            }
            catch {
                $result.ImageText = 'That folder could not be read'
            }
        }
        else {
            $result.ImageText = 'That folder no longer exists'
        }
    }

    $audio = [string]$AudioText.Text
    if (-not [string]::IsNullOrWhiteSpace($audio)) {
        if (Test-Path -LiteralPath $audio -PathType Leaf) {
            $result.AudioReady = $true
            $name = Split-Path -Leaf $audio
            if ($script:AudioDurationSeconds -gt 0) {
                $result.AudioText = "$name, $(Format-Clock $script:AudioDurationSeconds) long"
            }
            else {
                $result.AudioText = "$name, length measured at preview"
            }
        }
        else {
            $result.AudioText = 'That voiceover no longer exists'
        }
    }

    $watermark = [string]$WatermarkText.Text
    if (-not [string]::IsNullOrWhiteSpace($watermark)) {
        if (Test-Path -LiteralPath $watermark -PathType Leaf) {
            $result.WatermarkReady = $true
            $result.WatermarkText = "$(Split-Path -Leaf $watermark), loops for the whole video"
        }
        else {
            $result.WatermarkText = 'That overlay clip no longer exists'
        }
    }

    return $result
}

function Add-ReadinessCheck {
    param([string]$Label, [bool]$Done)
    $panel = [Windows.Controls.StackPanel]::new()
    $panel.Orientation = 'Horizontal'
    $panel.Margin = [Windows.Thickness]::new(0, 0, 14, 0)

    $mark = [Windows.Controls.TextBlock]::new()
    $mark.Text = if ($Done) { [char]0x2713 } else { [char]0x25CF }
    $mark.Foreground = if ($Done) { $script:OkBrush } else { $script:AccentBrush }
    $mark.FontSize = 11
    $mark.Margin = [Windows.Thickness]::new(0, 0, 5, 0)
    [void]$panel.Children.Add($mark)

    $text = [Windows.Controls.TextBlock]::new()
    $text.Text = $Label
    $text.Foreground = if ($Done) { $script:MutedBrush } else { $script:DimBrush }
    $text.FontSize = 11
    [void]$panel.Children.Add($text)

    [void]$ReadinessPanel.Children.Add($panel)
}

function Update-WorkflowState {
    # Recomputes every step summary, every badge and the readiness line from the
    # current controls. Called wherever a choice changes, so the rail and the
    # footer can never disagree with what is actually set.
    if ($script:IsLoading) { return }

    $summaries = Get-SourceSummaries
    $ImageSummaryText.Text = [string]$summaries.ImageText
    $AudioSummaryText.Text = [string]$summaries.AudioText
    $WatermarkSummaryText.Text = [string]$summaries.WatermarkText

    $hasImages = ([int]$summaries.ImageCount -gt 0)
    $hasAudio = [bool]$summaries.AudioReady
    # The same three answers on the tiles that stand in for the player until
    # there is a preview.
    $SingleTileImagesText.Text = [string]$summaries.ImageText
    $SingleTileAudioText.Text = [string]$summaries.AudioText
    $SingleTileWatermarkText.Text = [string]$summaries.WatermarkText
    $SingleTileImagesDot.Fill = if ($hasImages) { $script:OkBrush } else { $script:AccentBrush }
    $SingleTileAudioDot.Fill = if ($hasAudio) { $script:OkBrush } else { $script:AccentBrush }
    $SingleTileWatermarkDot.Fill = if ([bool]$summaries.WatermarkReady) { $script:OkBrush } else { $script:AccentBrush }
    $SingleEmptyHintText.Text = if ($hasImages -and $hasAudio -and [bool]$summaries.WatermarkReady) {
        'Everything is chosen. Preview 60s renders the first minute and opens it here with the storyboard.'
    }
    else { 'Once the three sources are chosen, Preview 60s renders the first minute and opens it here with the storyboard.' }
    if ($hasImages -and $hasAudio) {
        $sourceSummary = "$($summaries.ImageCount) photos, $(Format-Clock $script:AudioDurationSeconds) voiceover"
        if ($script:AudioDurationSeconds -le 0) { $sourceSummary = "$($summaries.ImageCount) photos, voiceover ready" }
    }
    elseif ($hasImages) { $sourceSummary = "$($summaries.ImageCount) photos, no voiceover yet" }
    elseif ($hasAudio) { $sourceSummary = 'Voiceover ready, no photos yet' }
    else { $sourceSummary = 'Nothing chosen yet' }
    Set-StepComplete -Name 'Media' -Complete ($hasImages -and $hasAudio) -Summary $sourceSummary

    $motionSummary = "$($MinimumDurationText.Text)-$($MaximumDurationText.Text)s holds, $($ZoomText.Text)% zoom"
    if ([bool]$CrossfadeCheckBox.IsChecked) { $motionSummary += ", $($CrossfadeSecondsText.Text)s dissolve" }
    Set-StepComplete -Name 'Motion' -Complete $true -Summary $motionSummary

    $captionMode = Get-ComboText $CaptionModeCombo
    $captionsDone = $true
    if ($captionMode -eq 'Off') { $captionSummary = 'Off' }
    else {
        $hasFile = (-not [string]::IsNullOrWhiteSpace([string]$script:CaptionPath)) -and (Test-Path -LiteralPath ([string]$script:CaptionPath) -PathType Leaf)
        $captionsDone = $hasFile
        $preset = (Get-ComboText $CaptionPresetCombo) -replace '^\d+\.\s*', ''
        $captionSummary = if ($hasFile) { "$captionMode, $preset" } else { "$captionMode, not generated yet" }
    }
    Set-StepComplete -Name 'Captions' -Complete $captionsDone -Summary $captionSummary

    Set-StepComplete -Name 'Blanking' -Complete $true -Summary "Blur $([int]$BlurSlider.Value), $([int]$BrightnessSlider.Value)% bright"

    $output = [string]$OutputText.Text
    $hasOutput = -not [string]::IsNullOrWhiteSpace($output)
    $exportSummary = if ($hasOutput) { "$(Get-ComboText $QualityCombo), $(Split-Path -Leaf $output)" } else { 'No destination chosen' }
    Set-StepComplete -Name 'Export' -Complete $hasOutput -Summary $exportSummary

    # The batch rail shows the same shared settings. Captions there speak for
    # the whole queue, so they say the mode and look rather than whether one
    # voiceover's captions happen to exist.
    $BatchNavMotionSummaryText.Text = $motionSummary
    $BatchNavCaptionsSummaryText.Text = if ($captionMode -eq 'Off') { 'Off' } else { "$captionMode, $((Get-ComboText $CaptionPresetCombo) -replace '^\d+\.\s*', '')" }
    $BatchNavBlankingSummaryText.Text = "Blur $([int]$BlurSlider.Value), $([int]$BrightnessSlider.Value)% bright"
    $BatchNavExportSummaryText.Text = "$(Get-ComboText $QualityCombo) quality, $(Get-ComboText $MotionQualityCombo) motion"

    if ($script:AppMode -eq 'Batch') {
        Update-BatchFooter
        return
    }

    # The footer says what is still missing rather than presenting a disabled
    # button with no explanation.
    $ReadinessPanel.Children.Clear()
    # While a render is running the footer belongs to its progress, not to a
    # checklist of things that are already settled.
    if ($null -ne $script:RenderState) { return }
    $missing = 0
    foreach ($check in @(
            @{ Label = 'Photos'; Done = $hasImages },
            @{ Label = 'Voiceover'; Done = $hasAudio },
            @{ Label = 'Captions'; Done = $captionsDone },
            @{ Label = 'Destination'; Done = $hasOutput })) {
        if (-not $check.Done) { $missing++ }
        Add-ReadinessCheck -Label ([string]$check.Label) -Done ([bool]$check.Done)
    }
    if ($missing -eq 0 -and -not $script:PreviewValid) {
        $StatusText.Text = 'Ready. Generate a preview first.'
    }
}

function Update-Estimate {
    if ($script:AudioDurationSeconds -le 0) {
        $EstimateText.Text = 'Available after voiceover scan'
        return
    }
    $quality = Get-ComboText $QualityCombo
    $size = Get-EstimatedOutputSizeMb -DurationSeconds $script:AudioDurationSeconds -Quality $quality
    $EstimateText.Text = "Approximately $size MB"
}

function Select-Folder {
    param([string]$Description, [string]$InitialPath = '')
    # Windows' own folder picker, so choosing an image folder looks and
    # navigates like choosing the voiceover next to it.
    try {
        return [CreatorFlowFolderPicker]::Show($Description, $InitialPath)
    }
    catch {
        # The shell dialog is present on every Windows this tool supports, so
        # reaching here means something unusual. Fall back rather than leaving
        # the person unable to pick a folder at all, and record why.
        Write-ToolDiagnostic 'The shell folder picker could not be opened; using the classic folder browser.' $_.Exception
    }

    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = $Description
    $dialog.ShowNewFolderButton = $false
    if ($InitialPath -and (Test-Path -LiteralPath $InitialPath -PathType Container)) {
        $dialog.SelectedPath = $InitialPath
    }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.SelectedPath
    }
    return $null
}

function Select-OpenFile {
    param([string]$Title, [string]$Filter, [string]$InitialPath = '')
    $dialog = [Microsoft.Win32.OpenFileDialog]::new()
    $dialog.Title = $Title
    $dialog.Filter = $Filter
    $dialog.CheckFileExists = $true
    if ($InitialPath) {
        if (Test-Path -LiteralPath $InitialPath -PathType Leaf) {
            $dialog.InitialDirectory = Split-Path -Parent $InitialPath
            $dialog.FileName = Split-Path -Leaf $InitialPath
        }
        elseif (Test-Path -LiteralPath $InitialPath -PathType Container) {
            $dialog.InitialDirectory = $InitialPath
        }
    }
    if ($dialog.ShowDialog($window)) {
        return $dialog.FileName
    }
    return $null
}

function Select-OpenFiles {
    param([string]$Title, [string]$Filter)
    $dialog = [Microsoft.Win32.OpenFileDialog]::new()
    $dialog.Title = $Title
    $dialog.Filter = $Filter
    $dialog.CheckFileExists = $true
    $dialog.Multiselect = $true
    if ($dialog.ShowDialog($window)) { return @($dialog.FileNames) }
    return @()
}

function Select-SaveFile {
    param([string]$Title, [string]$Filter, [string]$DefaultExtension, [string]$InitialPath = '')
    $dialog = [Microsoft.Win32.SaveFileDialog]::new()
    $dialog.Title = $Title
    $dialog.Filter = $Filter
    $dialog.DefaultExt = $DefaultExtension
    $dialog.AddExtension = $true
    $dialog.OverwritePrompt = $true
    if ($InitialPath) {
        if (Test-Path -LiteralPath (Split-Path -Parent $InitialPath) -PathType Container) {
            $dialog.InitialDirectory = Split-Path -Parent $InitialPath
            $dialog.FileName = Split-Path -Leaf $InitialPath
        }
    }
    if ($dialog.ShowDialog($window)) {
        return $dialog.FileName
    }
    return $null
}

function Get-ImageDimensions {
    param([string]$Path)
    $arguments = @(
        '-v', 'error', '-select_streams', 'v:0',
        '-show_entries', 'stream=width,height',
        '-of', 'csv=s=x:p=0', $Path
    )
    try {
        $output = & $script:FfprobePath @arguments 2>$null
        if ($LASTEXITCODE -ne 0 -or $output -notmatch '^(\d+)x(\d+)$') { return $null }
        return [pscustomobject]@{ Width = [int]$Matches[1]; Height = [int]$Matches[2] }
    }
    catch { return $null }
}

function Test-ReadableImage {
    param([string]$Path)
    return $null -ne (Get-ImageDimensions -Path $Path)
}

function Get-ValidatedImages {
    param([string]$Folder)
    $allImages = @(Get-SupportedImageFiles -Folder $Folder)
    if ($allImages.Count -eq 0) {
        throw 'The selected folder contains no supported JPG, JPEG, PNG, or WEBP images.'
    }

    $valid = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()
    $upscaled = [System.Collections.Generic.List[string]]::new()

    $StatusText.Text = "Checking $($allImages.Count) images for readability..."
    $window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
    foreach ($path in $allImages) {
        $dimensions = Get-ImageDimensions -Path $path
        if ($null -ne $dimensions) {
            $valid.Add($path)
            $fitScale = [Math]::Min(1920.0 / [double]$dimensions.Width, 1080.0 / [double]$dimensions.Height)
            if ($fitScale -gt 1.001) {
                $upscaled.Add("$([IO.Path]::GetFileName($path)) ($($dimensions.Width)x$($dimensions.Height))")
            }
        }
        else {
            $skipped.Add($path)
        }
    }

    if ($valid.Count -lt 2) {
        throw 'At least two readable images are required.'
    }
    # Both notes are advice, not questions: the video renders the same way
    # whatever the answer. As message boxes they stopped a batch once for every
    # folder in it until OK was clicked, so they are a status line and a log
    # entry now.
    $notes = [System.Collections.Generic.List[string]]::new()
    if ($skipped.Count -gt 0) {
        $names = @($skipped | ForEach-Object { [IO.Path]::GetFileName($_) })
        $shown = @($names | Select-Object -First 5) -join ', '
        $more = if ($names.Count -gt 5) { " and $($names.Count - 5) more" } else { '' }
        $notes.Add("Skipped $($skipped.Count) unreadable image(s): $shown$more.")
        Write-ToolDiagnostic "Unreadable images in $($Folder) were skipped: $($names -join '; ')"
    }
    if ($upscaled.Count -gt 0) {
        # Lanczos enlarges the small images.
        $notes.Add("$($upscaled.Count) of $($valid.Count) images in this folder are below 1080p and will be enlarged.")
        $examples = @($upscaled | Select-Object -First 8) -join '; '
        $more = if ($upscaled.Count -gt 8) { "; and $($upscaled.Count - 8) more" } else { '' }
        Write-ToolDiagnostic "Low-resolution images in $($Folder): $($upscaled.Count) of $($valid.Count) will be enlarged to fit 1080p. $examples$more"
    }
    if ($notes.Count -gt 0) { $StatusText.Text = $notes -join '  ' }
    return $valid.ToArray()
}

function Test-VideoStream {
    param([string]$Path)
    $arguments = @(
        '-v', 'error', '-select_streams', 'v:0',
        '-show_entries', 'stream=width,height',
        '-of', 'csv=s=x:p=0', $Path
    )
    $output = & $script:FfprobePath @arguments 2>$null
    return ($LASTEXITCODE -eq 0 -and $output -match '^\d+x\d+')
}

function Get-PlanSignature {
    param([string[]]$Images, [double]$Duration, [psobject]$Settings, [string]$AudioPath = '')
    $imageDetails = foreach ($path in ($Images | Sort-Object)) {
        $file = Get-Item -LiteralPath $path
        "$($file.FullName)|$($file.Length)|$($file.LastWriteTimeUtc.Ticks)"
    }
    if ([string]::IsNullOrWhiteSpace($AudioPath)) { $AudioPath = $AudioText.Text.Trim() }
    if ([string]::IsNullOrWhiteSpace($AudioPath)) { throw 'Select a valid voiceover file.' }
    $audio = Get-Item -LiteralPath $AudioPath
    return @(
        ($imageDetails -join ';'),
        "$($audio.FullName)|$($audio.Length)|$($audio.LastWriteTimeUtc.Ticks)",
        $Duration.ToString('0.######', [Globalization.CultureInfo]::InvariantCulture),
        $Settings.MinimumDuration,
        $Settings.MaximumDuration,
        '24'
    ) -join '||'
}

function Get-OverscanScale {
    # Fast never enlarges more than the zoom does; Best holds more detail than
    # the renderer this replaced. The middle is where the crop at maximum zoom
    # is exactly one delivery frame.
    #
    #   setting    detail   motion variance   speed    40 x 10min a day
    #   Fast        0.789        0.6%         2.34x         2.8 h
    #   Balanced    0.799        1.0%         2.04x         3.3 h
    #   Best        0.832        2.6%         1.12x         6.0 h
    #   (the old jittery renderer: 0.828, 16.1%, 3.07x, 2.2 h)
    param([psobject]$Settings)
    if ($null -eq $Settings.PSObject.Properties['MotionQuality']) { return 1.1 }
    switch ([string]$Settings.MotionQuality) {
        'Fast' { return 1.0 }
        'Best' { return 1.5 }
        default { return 1.1 }
    }
}

function Get-CrossfadeSeconds {
    param([psobject]$Settings)
    if ($null -eq $Settings.PSObject.Properties['Crossfade'] -or -not [bool]$Settings.Crossfade) { return 0.0 }
    if ($null -eq $Settings.PSObject.Properties['CrossfadeSeconds']) { return 0.5 }
    return [double]$Settings.CrossfadeSeconds
}

function Get-CurrentPreviewFingerprint {
    param([psobject]$Settings)
    $watermark = Get-Item -LiteralPath $WatermarkText.Text
    return @(
        $script:PlanSignature,
        $Settings.ZoomMaximum,
        $Settings.MotionQuality,
        $Settings.Crossfade,
        $Settings.CrossfadeSeconds,
        $Settings.BlurAmount,
        $Settings.BackgroundBrightness,
        $Settings.Quality,
        "$($watermark.FullName)|$($watermark.Length)|$($watermark.LastWriteTimeUtc.Ticks)",
        $script:RenderPipelineVersion
    ) -join '||'
}

function Get-CurrentFinalFingerprint {
    param(
        [psobject]$Settings,
        [string]$PreviewFingerprint,
        [string]$CaptionPath
    )
    if ([string]$Settings.CaptionMode -notin @('Burned only', 'Burned + SRT')) {
        return "$PreviewFingerprint||captions-not-burned"
    }
    $captionIdentity = 'caption-file-missing'
    if (-not [string]::IsNullOrWhiteSpace($CaptionPath) -and (Test-Path -LiteralPath $CaptionPath -PathType Leaf)) {
        $captionFile = Get-Item -LiteralPath $CaptionPath
        $captionIdentity = "$($captionFile.FullName)|$($captionFile.Length)|$($captionFile.LastWriteTimeUtc.Ticks)"
    }
    return @(
        $PreviewFingerprint,
        $captionIdentity,
        $Settings.CaptionFont,
        $Settings.CaptionFontSize,
        $Settings.CaptionBold,
        $Settings.CaptionTextColor,
        $Settings.CaptionOutlineColor,
        $Settings.CaptionOutlineWidth,
        $Settings.CaptionShadow,
        $Settings.CaptionBackgroundColor,
        $Settings.CaptionBackgroundOpacity,
        $Settings.CaptionAlignment,
        $Settings.CaptionPositionX,
        $Settings.CaptionPositionY,
        $Settings.CaptionMaxWidth,
        $Settings.CaptionWordsPerLine,
        $Settings.CaptionLineSpacing
    ) -join '||'
}

function Ensure-TimelinePlan {
    param([string[]]$Images, [double]$Duration, [psobject]$Settings)
    $signature = Get-PlanSignature -Images $Images -Duration $Duration -Settings $Settings
    $canReusePlan = $false
    if ($null -ne $script:CurrentPlan) {
        $expectedFrames = [int][Math]::Ceiling($Duration * 24)
        $sameDuration = [Math]::Abs([double]$script:CurrentPlan.AudioDurationSeconds - $Duration) -lt 0.05
        $sameMinimum = [Math]::Abs([double]$script:CurrentPlan.MinimumDurationSeconds - $Settings.MinimumDuration) -lt 0.001
        $sameMaximum = [Math]::Abs([double]$script:CurrentPlan.MaximumDurationSeconds - $Settings.MaximumDuration) -lt 0.001
        $sameFrames = [int]$script:CurrentPlan.TotalFrames -eq $expectedFrames

        $currentByName = @{}
        foreach ($imagePath in $Images) {
            $currentByName[[IO.Path]::GetFileName($imagePath).ToLowerInvariant()] = $imagePath
        }
        $plannedNames = @($script:CurrentPlan.Items | ForEach-Object { ([string]$_.ImageName).ToLowerInvariant() } | Sort-Object -Unique)
        $currentNames = @($currentByName.Keys | Sort-Object)
        $sameImages = (($plannedNames -join '|') -eq ($currentNames -join '|'))

        if ($sameDuration -and $sameMinimum -and $sameMaximum -and $sameFrames -and $sameImages) {
            foreach ($item in $script:CurrentPlan.Items) {
                $item.ImagePath = $currentByName[([string]$item.ImageName).ToLowerInvariant()]
            }
            $canReusePlan = $true
        }
    }

    if (-not $canReusePlan) {
        $StatusText.Text = 'Creating randomized timeline...'
        $window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
        $script:CurrentPlan = New-TimelinePlan `
            -ImagePaths $Images `
            -AudioDurationSeconds $Duration `
            -MinimumDurationSeconds $Settings.MinimumDuration `
            -MaximumDurationSeconds $Settings.MaximumDuration `
            -Fps $script:DeliveryFps
    }
    $script:PlanSignature = $signature
    Update-StoryboardUI
}

function Quote-ProcessArgument {
    param([AllowEmptyString()][string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append(('\' * ($backslashes * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Join-ProcessArguments {
    param([string[]]$Arguments)
    return (($Arguments | ForEach-Object { Quote-ProcessArgument $_ }) -join ' ')
}

function Set-RenderControls {
    param([bool]$Rendering)
    $PreviewButton.IsEnabled = -not $Rendering
    $EmptyPreviewButton.IsEnabled = -not $Rendering
    $OpenProjectButton.IsEnabled = -not $Rendering
    $SaveProjectButton.IsEnabled = -not $Rendering
    foreach ($control in @($ScanChannelsButton, $AddVideoButton, $SavedProjectsButton, $ClearFinishedButton, $EmptyScanButton, $EmptyAddButton,
            $RenderAllButton, $BatchResumeButton, $SelectedPreviewButton, $SelectedCaptionsButton, $SelectedRemoveButton)) {
        $control.IsEnabled = -not $Rendering
    }
    $GenerateCaptionsButton.IsEnabled = -not $Rendering
    $EditCaptionsButton.IsEnabled = -not $Rendering
    $CancelButton.IsEnabled = $Rendering
    if ($Rendering) {
        $FinalButton.IsEnabled = $false
        $OpenFolderButton.IsEnabled = $false
        # Stamped in one place rather than in each of the five render states, so
        # every kind of render can report a finish time without them all having
        # to remember to record when they began.
        if ($null -ne $script:RenderState) {
            if ($script:RenderState.PSObject.Properties['StartedUtc']) { $script:RenderState.StartedUtc = [DateTime]::UtcNow }
            else { $script:RenderState | Add-Member -NotePropertyName StartedUtc -NotePropertyValue ([DateTime]::UtcNow) }
            # Only the already-decided value. Asking for it here would run the
            # encoder session probe on the interface thread and freeze the
            # window for several seconds at the start of every preview.
            if ($null -ne $script:RecommendedParallelSegments) {
                $lanes = [int]$script:RecommendedParallelSegments
                if ($script:RenderState.PSObject.Properties['Lanes']) { $script:RenderState.Lanes = $lanes }
                else { $script:RenderState | Add-Member -NotePropertyName Lanes -NotePropertyValue $lanes }
            }
        }
        if ($null -ne $ReadinessPanel) { $ReadinessPanel.Children.Clear() }
    }
    else {
        $FinalButton.IsEnabled = $script:PreviewValid
        if ($null -ne $RenderEtaText) { $RenderEtaText.Text = '' }
        if ($null -ne $RenderDetailText) { $RenderDetailText.Text = '' }
        Update-WorkflowState
    }
    Update-QueueEditing
    Update-SingleView
    Update-BatchInspector
    Update-BatchFooter
}

function Stop-PreviewPlayback {
    try {
        $PreviewMedia.Stop()
        $PlayPauseButton.Content = 'Play'
    }
    catch {}
}

function Read-CaptionProgress {
    param([string]$Path)
    $result = [pscustomobject]@{ Percent = 0.0; Message = 'Preparing automatic captions...' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }
    try {
        $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $percentMatch = [regex]::Match($text, '(?m)^percent=([0-9.]+)')
        $messageMatch = [regex]::Match($text, '(?m)^message=(.*)$')
        if ($percentMatch.Success) {
            $result.Percent = [double]::Parse($percentMatch.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
        }
        if ($messageMatch.Success) { $result.Message = $messageMatch.Groups[1].Value.Trim() }
    }
    catch {}
    return $result
}

function Remove-CaptionRunDirectory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    $allowedRoot = [IO.Path]::GetFullPath($script:DataRoot).TrimEnd('\') + '\'
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\') + '\'
    if ($resolved.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Start-CaptionGeneration {
    # Without -AudioPath this captions the Single video voiceover. A queued
    # video passes its own voiceover, which leaves the Single video captions
    # and the player overlay alone.
    param([bool]$Force = $false, [string]$AudioPath = '')
    try {
        Assert-FFmpegAvailable
        $audioPath = if ([string]::IsNullOrWhiteSpace($AudioPath)) { $AudioText.Text.Trim() } else { $AudioPath.Trim() }
        $isSingleVoiceover = [string]::Equals($audioPath, $AudioText.Text.Trim(), [StringComparison]::OrdinalIgnoreCase)
        if (-not (Test-VoiceoverFile $audioPath)) {
            throw 'Select a valid voiceover file before generating captions.'
        }
        $outputSrt = Get-CaptionCachePath -AudioPath $audioPath -DataRoot $script:DataRoot
        if (-not $Force -and (Test-Path -LiteralPath $outputSrt -PathType Leaf)) {
            if ($isSingleVoiceover) {
                $script:CaptionPath = $outputSrt
                $script:LiveCaptionCacheSignature = ''
                Refresh-LiveCaptionEntries
                Update-LiveCaptionText
                $CaptionStatusText.Text = 'Automatic captions are ready.'
            }
            return $true
        }

        $runDirectory = Join-Path $script:DataRoot "caption-run-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
        $jobPath = Join-Path $runDirectory 'caption-job.json'
        $progressPath = Join-Path $runDirectory 'progress.txt'
        $errorPath = Join-Path $runDirectory 'caption-error.log'
        $job = [ordered]@{
            FfmpegPath = $script:FfmpegPath
            AudioPath = $audioPath
            EngineRoot = Get-CaptionEngineRoot
            OutputSrt = $outputSrt
            ProgressPath = $progressPath
            ErrorPath = $errorPath
        }
        [IO.File]::WriteAllText($jobPath, ($job | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
        $workerPath = Join-Path $script:AppRoot 'CaptionWorker.ps1'
        $argumentLine = Join-ProcessArguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $workerPath, '-JobPath', $jobPath)
        $script:CancelRequested = $false
        $script:RenderState = [pscustomobject]@{
            Kind = 'Captions'
            RunDirectory = $runDirectory
            ProgressPath = $progressPath
            ErrorPath = $errorPath
            OutputSrt = $outputSrt
            AudioPath = $audioPath
            IsSingleVoiceover = $isSingleVoiceover
            DurationSeconds = 1.0
            Encoder = 'offline whisper.cpp'
        }
        $RenderProgress.Value = 0
        $StatusText.Text = 'Starting automatic caption generation...'
        if ($isSingleVoiceover) { $CaptionStatusText.Text = 'Preparing offline caption engine...' }
        Set-RenderControls $true
        $script:RenderProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentLine -PassThru -WindowStyle Hidden
        Write-ToolDiagnostic "Caption generation started. PID=$($script:RenderProcess.Id)"
        $renderTimer.Start()
        return $false
    }
    catch {
        Write-ToolDiagnostic 'Caption generation could not start.' $_.Exception
        if ($null -ne $script:RenderState) { Remove-CaptionRunDirectory $script:RenderState.RunDirectory }
        $script:RenderProcess = $null
        $script:RenderState = $null
        $script:PendingCaptionEditorAudio = ''
        Set-RenderControls $false
        Show-ErrorMessage $_.Exception.Message 'Could not generate captions'
        return $false
    }
}

function Complete-CaptionGeneration {
    $state = $script:RenderState
    $process = $script:RenderProcess
    $pendingKind = $script:PendingRenderAfterCaptions
    $script:PendingRenderAfterCaptions = $null
    # A queued video's Edit captions waits for its captions to exist, then
    # opens the editor on them.
    $pendingEditorAudio = [string]$script:PendingCaptionEditorAudio
    $script:PendingCaptionEditorAudio = ''
    $isSingleVoiceover = ($null -eq $state) -or -not $state.PSObject.Properties['IsSingleVoiceover'] -or [bool]$state.IsSingleVoiceover
    try {
        $renderTimer.Stop()
        $process.WaitForExit()
        $process.Refresh()
        if ($script:CancelRequested) {
            $StatusText.Text = 'Caption generation cancelled.'
            if ($isSingleVoiceover) { $CaptionStatusText.Text = 'Captions were not changed.' }
            $pendingEditorAudio = ''
            return
        }
        if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $state.OutputSrt -PathType Leaf)) {
            $message = 'The offline caption engine failed.'
            if (Test-Path -LiteralPath $state.ErrorPath -PathType Leaf) {
                $raw = Get-Content -LiteralPath $state.ErrorPath -Raw -ErrorAction SilentlyContinue
                if (-not [string]::IsNullOrWhiteSpace($raw)) { $message = $raw.Trim() }
            }
            throw $message
        }
        if ($isSingleVoiceover) {
            $script:CaptionPath = $state.OutputSrt
            $script:LiveCaptionCacheSignature = ''
            Refresh-LiveCaptionEntries
            Update-LiveCaptionText
            $CaptionStatusText.Text = 'Automatic captions are ready.'
        }
        $RenderProgress.Value = 100
        $StatusText.Text = 'Automatic captions are ready and cached for this voiceover.'
        Write-ToolDiagnostic "Caption generation completed at $($state.OutputSrt)"
    }
    catch {
        Write-ToolDiagnostic 'Caption generation failed.' $_.Exception
        Show-ErrorMessage $_.Exception.Message 'Caption generation failed'
        if ($isSingleVoiceover) { $CaptionStatusText.Text = 'Caption generation failed; see the diagnostic log.' }
        $pendingKind = $null
        $pendingEditorAudio = ''
    }
    finally {
        if ($null -ne $state) { Remove-CaptionRunDirectory $state.RunDirectory }
        $script:RenderProcess = $null
        $script:RenderState = $null
        Set-RenderControls $false
    }
    if ($pendingKind) {
        Start-VideoRender $pendingKind
    }
    elseif (-not [string]::IsNullOrWhiteSpace($pendingEditorAudio)) {
        Show-CaptionEditor -AudioPath $pendingEditorAudio
    }
}

function ConvertFrom-SrtTimestamp {
    param([string]$Value)
    try {
        return [TimeSpan]::ParseExact($Value.Trim(), 'hh\:mm\:ss\,fff', [Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        throw "Invalid caption time '$Value'. Use HH:MM:SS,mmm."
    }
}

function ConvertTo-SrtTimestamp {
    param([TimeSpan]$Value)
    $hours = [int][Math]::Floor($Value.TotalHours)
    return ('{0:00}:{1:00}:{2:00},{3:000}' -f $hours, $Value.Minutes, $Value.Seconds, $Value.Milliseconds)
}

function Read-SrtEntries {
    param([string]$Path)
    $collection = [Collections.ObjectModel.ObservableCollection[object]]::new()
    $source = Get-Content -LiteralPath $Path -Raw
    $pattern = '(?ms)^\s*\d+\s*\r?\n(?<start>\d{2}:\d{2}:\d{2},\d{3})\s*-->\s*(?<end>\d{2}:\d{2}:\d{2},\d{3})[^\r\n]*\r?\n(?<text>.*?)(?=\r?\n\s*\r?\n|\z)'
    $matches = [regex]::Matches($source, $pattern)
    $index = 1
    foreach ($match in $matches) {
        $collection.Add([pscustomobject]@{
                Number = $index
                Start = $match.Groups['start'].Value
                End = $match.Groups['end'].Value
                Text = $match.Groups['text'].Value.Trim()
            })
        $index++
    }
    return ,$collection
}

function ConvertTo-WpfBrush {
    param([string]$Hex, [double]$OpacityPercent = 100.0)
    try {
        $color = [Windows.Media.ColorConverter]::ConvertFromString($Hex)
        $color.A = [byte][Math]::Round(255.0 * [Math]::Max(0.0, [Math]::Min(100.0, $OpacityPercent)) / 100.0)
        return [Windows.Media.SolidColorBrush]::new($color)
    }
    catch { return [Windows.Media.Brushes]::Transparent }
}

function Get-EffectiveCaptionTextColor {
    param([string]$TextColor, [string]$BackgroundColor, [double]$BackgroundOpacity)
    # An opaque light caption band with light text looks like an empty white
    # rectangle in both the live player and the rendered video. Keep the
    # selected colour unless that combination fails a basic contrast check.
    if ($BackgroundOpacity -le 0.0) { return $TextColor }
    try {
        $foreground = [Windows.Media.ColorConverter]::ConvertFromString($TextColor)
        $background = [Windows.Media.ColorConverter]::ConvertFromString($BackgroundColor)
        $luminance = {
            param([Windows.Media.Color]$Color)
            return ((0.2126 * $Color.R) + (0.7152 * $Color.G) + (0.0722 * $Color.B)) / 255.0
        }
        $foregroundLuminance = & $luminance $foreground
        $backgroundLuminance = & $luminance $background
        $contrast = ([Math]::Max($foregroundLuminance, $backgroundLuminance) + 0.05) / ([Math]::Min($foregroundLuminance, $backgroundLuminance) + 0.05)
        if ($contrast -lt 3.0) { return '#111111' }
    }
    catch {}
    return $TextColor
}

function Show-CaptionColorPicker {
    param([Windows.Controls.TextBox]$TargetTextBox)
    $dialog = [Windows.Forms.ColorDialog]::new()
    $dialog.FullOpen = $true
    $dialog.AnyColor = $true
    try {
        if ($TargetTextBox.Text -match '^#[0-9A-Fa-f]{6}$') {
            $dialog.Color = [Drawing.ColorTranslator]::FromHtml($TargetTextBox.Text)
        }
        if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
            $TargetTextBox.Text = '#{0:X2}{1:X2}{2:X2}' -f $dialog.Color.R, $dialog.Color.G, $dialog.Color.B
            Apply-LiveCaptionStyle
        }
    }
    finally { $dialog.Dispose() }
}

function Get-LiveCaptionVideoRect {
    $canvasWidth = [double]$CaptionOverlayCanvas.ActualWidth
    $canvasHeight = [double]$CaptionOverlayCanvas.ActualHeight
    if ($canvasWidth -le 0 -or $canvasHeight -le 0) { return $null }
    $aspect = 16.0 / 9.0
    if (($canvasWidth / $canvasHeight) -gt $aspect) {
        $height = $canvasHeight
        $width = $height * $aspect
        $left = ($canvasWidth - $width) / 2.0
        $top = 0.0
    }
    else {
        $width = $canvasWidth
        $height = $width / $aspect
        $left = 0.0
        $top = ($canvasHeight - $height) / 2.0
    }
    return [pscustomobject]@{ Left=$left; Top=$top; Width=$width; Height=$height }
}

function Update-LiveCaptionLayout {
    if ($null -eq $LiveCaptionBorder -or $LiveCaptionBorder.Visibility -ne [Windows.Visibility]::Visible) { return }
    $video = Get-LiveCaptionVideoRect
    if ($null -eq $video) { return }
    $width = $video.Width * ([double]$CaptionMaxWidthSlider.Value / 100.0)
    # MaxWidth controls wrapping while the background box remains compact
    # around short captions, matching libass more closely than a fixed band.
    $LiveCaptionBorder.Width = [double]::NaN
    $LiveCaptionBorder.MaxWidth = [Math]::Max(120.0, $width)
    # libass SRT styles use a 288-line design grid. Matching that scale keeps
    # the live WPF overlay close to the final burned result.
    $LiveCaptionText.FontSize = [Math]::Max(8.0, [double]$CaptionSizeSlider.Value * $video.Height / 288.0)
    $LiveCaptionText.LineHeight = $LiveCaptionText.FontSize * [double]$CaptionLineSpacingSlider.Value
    $LiveCaptionBorder.UpdateLayout()
    $x = $video.Left + ($video.Width * [double]$CaptionPositionXSlider.Value / 100.0)
    $y = $video.Top + ($video.Height * [double]$CaptionPositionYSlider.Value / 100.0)
    $left = [Math]::Max($video.Left, [Math]::Min($video.Left + $video.Width - $LiveCaptionBorder.ActualWidth, $x - ($LiveCaptionBorder.ActualWidth / 2.0)))
    $top = [Math]::Max($video.Top, [Math]::Min($video.Top + $video.Height - $LiveCaptionBorder.ActualHeight, $y - ($LiveCaptionBorder.ActualHeight / 2.0)))
    [Windows.Controls.Canvas]::SetLeft($LiveCaptionBorder, $left)
    [Windows.Controls.Canvas]::SetTop($LiveCaptionBorder, $top)
}

function Apply-LiveCaptionStyle {
    if ($null -eq $LiveCaptionText) { return }
    $font = Get-ComboText $CaptionFontCombo
    if (-not [string]::IsNullOrWhiteSpace($font)) { $LiveCaptionText.FontFamily = [Windows.Media.FontFamily]::new($font) }
    $LiveCaptionText.FontWeight = if ([bool]$CaptionBoldCheckBox.IsChecked) { [Windows.FontWeights]::Bold } else { [Windows.FontWeights]::Normal }
    $effectiveTextColor = Get-EffectiveCaptionTextColor -TextColor $CaptionTextColorText.Text -BackgroundColor $CaptionBackgroundColorText.Text -BackgroundOpacity ([double]$CaptionBackgroundOpacitySlider.Value)
    $LiveCaptionText.Foreground = ConvertTo-WpfBrush $effectiveTextColor 100
    $backgroundOpacity = [double]$CaptionBackgroundOpacitySlider.Value
    # A null background is materially different from a transparent brush for
    # the MediaElement composition path: it prevents an empty white surface
    # from being painted over the video when the caption box is disabled.
    $LiveCaptionBorder.Background = if ($backgroundOpacity -le 0.0) { $null } else { ConvertTo-WpfBrush $CaptionBackgroundColorText.Text $backgroundOpacity }
    $alignment = Get-ComboText $CaptionAlignmentCombo
    $LiveCaptionText.TextAlignment = switch ($alignment) { 'Left' { [Windows.TextAlignment]::Left }; 'Right' { [Windows.TextAlignment]::Right }; default { [Windows.TextAlignment]::Center } }
    $effect = [Windows.Media.Effects.DropShadowEffect]::new()
    try { $effect.Color = [Windows.Media.ColorConverter]::ConvertFromString($CaptionOutlineColorText.Text) } catch { $effect.Color = [Windows.Media.Colors]::Black }
    $effect.BlurRadius = [Math]::Max(0.1, ([double]$CaptionOutlineSlider.Value * 2.2) + ([double]$CaptionShadowSlider.Value * 0.5))
    $effect.ShadowDepth = [double]$CaptionShadowSlider.Value
    $effect.Opacity = if ($CaptionOutlineSlider.Value -gt 0 -or $CaptionShadowSlider.Value -gt 0) { 1.0 } else { 0.0 }
    $LiveCaptionText.Effect = $effect
    Update-CaptionControlLabels
    Update-LiveCaptionLayout
}

function Refresh-LiveCaptionEntries {
    if ([string]::IsNullOrWhiteSpace([string]$script:CaptionPath) -or -not (Test-Path -LiteralPath $script:CaptionPath -PathType Leaf)) {
        $script:LiveCaptionEntries = @()
        $script:LiveCaptionCacheSignature = ''
        return
    }
    $file = Get-Item -LiteralPath $script:CaptionPath
    $signature = "$($file.FullName)|$($file.Length)|$($file.LastWriteTimeUtc.Ticks)"
    if ($signature -eq $script:LiveCaptionCacheSignature) { return }
    $loaded = Read-SrtEntries -Path $script:CaptionPath
    $script:LiveCaptionEntries = @($loaded)
    $script:LiveCaptionCacheSignature = $signature
}

function Update-LiveCaptionText {
    if ((Get-ComboText $CaptionModeCombo) -eq 'Off' -or $null -eq $PreviewMedia.Source) {
        $LiveCaptionBorder.Visibility = [Windows.Visibility]::Collapsed
        return
    }
    if ($null -eq $script:LiveCaptionOverrideEntries) { Refresh-LiveCaptionEntries }
    $entries = if ($null -ne $script:LiveCaptionOverrideEntries) { @($script:LiveCaptionOverrideEntries) } else { @($script:LiveCaptionEntries) }
    $position = $PreviewMedia.Position
    $activeText = ''
    foreach ($entry in $entries) {
        try {
            $start = ConvertFrom-SrtTimestamp ([string]$entry.Start)
            $end = ConvertFrom-SrtTimestamp ([string]$entry.End)
            if ($position -ge $start -and $position -lt $end) { $activeText = [string]$entry.Text; break }
        }
        catch {}
    }
    if ([string]::IsNullOrWhiteSpace($activeText)) {
        $LiveCaptionBorder.Visibility = [Windows.Visibility]::Collapsed
        return
    }
    $formattedText = Format-CaptionText -Text $activeText -MaxWordsPerLine ([int][Math]::Round($CaptionWordsPerLineSlider.Value))
    # The player timer runs four times per second. Rebuilding WPF effects and
    # forcing a layout pass on every tick eventually starves MediaElement and
    # makes playback appear to slow down. Only redraw when the active caption
    # actually changes; style controls already redraw explicitly.
    if ($LiveCaptionBorder.Visibility -eq [Windows.Visibility]::Visible -and
        $script:LastLiveCaptionText -eq $formattedText -and
        $LiveCaptionText.Text -eq $formattedText) {
        return
    }
    $script:LastLiveCaptionText = $formattedText
    $LiveCaptionText.Text = $formattedText
    $LiveCaptionBorder.Visibility = [Windows.Visibility]::Visible
    Apply-LiveCaptionStyle
}

function Save-SrtEntries {
    param([Collections.IEnumerable]$Entries, [string]$Path)
    $builder = [Text.StringBuilder]::new()
    $index = 1
    $previousStart = [TimeSpan]::Zero
    foreach ($entry in $Entries) {
        $start = ConvertFrom-SrtTimestamp ([string]$entry.Start)
        $end = ConvertFrom-SrtTimestamp ([string]$entry.End)
        if ($end -le $start) { throw "Caption $index must end after it starts." }
        if ($index -gt 1 -and $start -lt $previousStart) { throw "Caption $index starts before the previous caption. Sort the times first." }
        if ([string]::IsNullOrWhiteSpace([string]$entry.Text)) { throw "Caption $index has no text." }
        [void]$builder.AppendLine([string]$index)
        [void]$builder.AppendLine("$(ConvertTo-SrtTimestamp $start) --> $(ConvertTo-SrtTimestamp $end)")
        [void]$builder.AppendLine(([string]$entry.Text).Trim())
        [void]$builder.AppendLine()
        $entry.Number = $index
        $previousStart = $start
        $index++
    }
    if ($index -eq 1) { throw 'At least one caption is required.' }
    [IO.File]::WriteAllText($Path, $builder.ToString(), [Text.UTF8Encoding]::new($false))
}

function Show-CaptionEditor {
    # -AudioPath edits a queued video's captions. The live overlay on the player
    # only follows along when that voiceover is also the one in Single video,
    # because otherwise the player is showing a different video.
    param([string]$AudioPath = '')
    try {
        $audioPath = if ([string]::IsNullOrWhiteSpace($AudioPath)) { $AudioText.Text.Trim() } else { $AudioPath.Trim() }
        $isSingleVoiceover = [string]::Equals($audioPath, $AudioText.Text.Trim(), [StringComparison]::OrdinalIgnoreCase)
        if (-not (Test-Path -LiteralPath $audioPath -PathType Leaf)) { throw 'Select a voiceover first.' }
        $captionPath = Get-CaptionCachePath -AudioPath $audioPath -DataRoot $script:DataRoot
        if (-not (Test-Path -LiteralPath $captionPath -PathType Leaf)) {
            Show-InfoMessage 'Generate automatic captions first, then open the editor.' 'Captions not generated'
            return
        }
        $entries = Read-SrtEntries -Path $captionPath
        if ($entries.Count -eq 0) { throw 'The caption file contains no readable SRT entries.' }
        $editorXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Caption Editor" Width="1080" Height="700" MinWidth="850" MinHeight="560" WindowStartupLocation="CenterOwner"
        Background="#17171A" Foreground="White" FontFamily="Segoe UI">
    <Window.Resources>
        <Style TargetType="TextBlock"><Setter Property="Foreground" Value="White"/></Style>
        <Style TargetType="Button"><Setter Property="Background" Value="#26262B"/><Setter Property="Foreground" Value="White"/><Setter Property="BorderBrush" Value="#41414A"/><Setter Property="Padding" Value="12,7"/><Setter Property="Margin" Value="3"/></Style>
        <Style TargetType="TextBox"><Setter Property="Background" Value="#E9E9E6"/><Setter Property="Foreground" Value="White"/><Setter Property="BorderBrush" Value="#41414A"/><Setter Property="Padding" Value="7"/><Setter Property="Margin" Value="3"/></Style>
        <!-- DataGrid's default row template uses a white alternate row.  Set
             every layer explicitly so white caption text stays readable. -->
        <Style TargetType="DataGridColumnHeader"><Setter Property="Background" Value="#26262B"/><Setter Property="Foreground" Value="White"/><Setter Property="BorderBrush" Value="#41414A"/><Setter Property="Padding" Value="8,7"/></Style>
        <Style TargetType="DataGridCell"><Setter Property="Background" Value="Transparent"/><Setter Property="Foreground" Value="White"/><Setter Property="BorderBrush" Value="#33333A"/><Setter Property="VerticalContentAlignment" Value="Center"/><Setter Property="Padding" Value="7,3"/></Style>
        <Style TargetType="DataGridRow"><Setter Property="Background" Value="#101012"/><Setter Property="Foreground" Value="White"/><Setter Property="VerticalContentAlignment" Value="Center"/><Style.Triggers><Trigger Property="ItemsControl.AlternationIndex" Value="1"><Setter Property="Background" Value="#1E1E22"/></Trigger><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#2A2119"/></Trigger></Style.Triggers></Style>
    </Window.Resources>
    <Grid Margin="14">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel><TextBlock Text="Caption Editor" FontSize="22" FontWeight="SemiBold"/><TextBlock Text="Changes appear live on the main player. You can use its Play, Pause, seek, style controls, and drag handles while this editor is open." Foreground="#7E7E7A" Margin="0,4,0,10" TextWrapping="Wrap"/></StackPanel>
            <Button x:Name="PreviewCaptionButton" Grid.Column="1" Content="Play Selected Caption" VerticalAlignment="Top" Background="#2A2119"/>
        </Grid>
        <Border Grid.Row="1" Background="#1E1E22" BorderBrush="#33333A" BorderThickness="1" CornerRadius="7" Padding="8" Margin="0,0,0,10">
            <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBox x:Name="FindText" ToolTip="Text to find"/>
                <TextBox x:Name="ReplaceText" Grid.Column="1" ToolTip="Replacement text"/>
                <Button x:Name="ReplaceAllButton" Grid.Column="2" Content="Replace All"/>
                <Button x:Name="AddCaptionButton" Grid.Column="3" Content="Add Row"/>
                <Button x:Name="SplitCaptionButton" Grid.Column="4" Content="Split"/>
                <Button x:Name="MergeCaptionButton" Grid.Column="5" Content="Merge Next"/>
                <Button x:Name="DeleteCaptionButton" Grid.Column="6" Content="Delete" Background="#5A3A38"/>
            </Grid>
        </Border>
        <DataGrid x:Name="CaptionGrid" Grid.Row="2" AutoGenerateColumns="False" CanUserAddRows="False" CanUserDeleteRows="False"
                  HeadersVisibility="Column" GridLinesVisibility="Horizontal" RowHeight="44" AlternationCount="2" Background="#101012" Foreground="White"
                  BorderBrush="#33333A" HorizontalGridLinesBrush="#33333A" AlternatingRowBackground="#1E1E22"
                  SelectionMode="Single" SelectionUnit="FullRow">
            <DataGrid.Columns>
                <DataGridTextColumn Header="#" Binding="{Binding Number}" Width="45" IsReadOnly="True"/>
                <DataGridTextColumn Header="Start" Binding="{Binding Start, UpdateSourceTrigger=PropertyChanged}" Width="135"/>
                <DataGridTextColumn Header="End" Binding="{Binding End, UpdateSourceTrigger=PropertyChanged}" Width="135"/>
                <DataGridTextColumn Header="Caption text" Binding="{Binding Text, UpdateSourceTrigger=PropertyChanged}" Width="*"/>
            </DataGrid.Columns>
        </DataGrid>
        <Grid Grid.Row="3" Margin="0,10,0,0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBlock x:Name="EditorStatus" Text="Ready" Foreground="#7E7E7A"/>
            <StackPanel Grid.Column="1" Orientation="Horizontal"><Button x:Name="CancelEditorButton" Content="Cancel"/><Button x:Name="SaveEditorButton" Content="Save Captions" Background="#E0913F" BorderBrush="#E0913F" FontWeight="SemiBold"/></StackPanel>
        </Grid>
    </Grid>
</Window>
'@
        $reader = [Xml.XmlNodeReader]::new([xml]$editorXaml)
        $editor = [Windows.Markup.XamlReader]::Load($reader)
        $editor.Owner = $window
        Set-WindowIcon -Target $editor
        $grid = $editor.FindName('CaptionGrid')
        $grid.ItemsSource = $entries
        $findText = $editor.FindName('FindText')
        $replaceText = $editor.FindName('ReplaceText')
        $editorStatus = $editor.FindName('EditorStatus')
        $script:CaptionEditorSaved = $false
        $script:CaptionEditorOpen = $true
        if ($isSingleVoiceover) { $script:LiveCaptionOverrideEntries = $entries }
        $editorLiveTimer = [Windows.Threading.DispatcherTimer]::new()
        $editorLiveTimer.Interval = [TimeSpan]::FromMilliseconds(120)
        $editorLiveTimer.Add_Tick({
                if ($isSingleVoiceover) {
                    $script:LiveCaptionOverrideEntries = $entries
                    Update-LiveCaptionText
                }
            })
        $editorLiveTimer.Start()
        if (-not $isSingleVoiceover) { $editor.Title = "Caption Editor - $([IO.Path]::GetFileName($audioPath))" }

        $editor.Add_SourceInitialized({
                try { $handle = [Windows.Interop.WindowInteropHelper]::new($editor).Handle; $enabled = 1; [void][CreatorFlowWindowTheme]::DwmSetWindowAttribute($handle, 20, [ref]$enabled, 4) } catch {}
            })
        $editor.FindName('AddCaptionButton').Add_Click({
                $start = if ($entries.Count -gt 0) { ConvertFrom-SrtTimestamp ([string]$entries[$entries.Count - 1].End) } else { [TimeSpan]::Zero }
                $end = $start.Add([TimeSpan]::FromSeconds(3))
                $entries.Add([pscustomobject]@{ Number = $entries.Count + 1; Start = ConvertTo-SrtTimestamp $start; End = ConvertTo-SrtTimestamp $end; Text = 'New caption' })
                $grid.SelectedIndex = $entries.Count - 1
                $grid.ScrollIntoView($grid.SelectedItem)
                Update-LiveCaptionText
            })
        $editor.FindName('DeleteCaptionButton').Add_Click({
                if ($null -eq $grid.SelectedItem) { return }
                [void]$entries.Remove($grid.SelectedItem)
                for ($i = 0; $i -lt $entries.Count; $i++) { $entries[$i].Number = $i + 1 }
                $grid.Items.Refresh()
                Update-LiveCaptionText
            })
        $editor.FindName('SplitCaptionButton').Add_Click({
                if ($null -eq $grid.SelectedItem) { $editorStatus.Text = 'Select a caption first.'; return }
                try {
                    $grid.CommitEdit([Windows.Controls.DataGridEditingUnit]::Cell, $true) | Out-Null
                    $selectedIndex = $grid.SelectedIndex
                    $entry = $entries[$selectedIndex]
                    $start = ConvertFrom-SrtTimestamp ([string]$entry.Start)
                    $end = ConvertFrom-SrtTimestamp ([string]$entry.End)
                    $split = if ($isSingleVoiceover) { $PreviewMedia.Position } else { [TimeSpan]::Zero }
                    if ($split -le $start.Add([TimeSpan]::FromMilliseconds(150)) -or $split -ge $end.Subtract([TimeSpan]::FromMilliseconds(150))) {
                        $split = $start.Add([TimeSpan]::FromTicks([int64](($end - $start).Ticks / 2)))
                    }
                    $words = @(([string]$entry.Text) -split '\s+' | Where-Object { $_ })
                    $wordSplit = [Math]::Max(1, [Math]::Min($words.Count - 1, [int][Math]::Ceiling($words.Count / 2.0)))
                    $firstText = if ($words.Count -gt 1) { ($words[0..($wordSplit - 1)] -join ' ') } else { [string]$entry.Text }
                    $secondText = if ($words.Count -gt 1) { ($words[$wordSplit..($words.Count - 1)] -join ' ') } else { 'Continued' }
                    $originalEnd = [string]$entry.End
                    $entry.End = ConvertTo-SrtTimestamp $split
                    $entry.Text = $firstText
                    $entries.Insert($selectedIndex + 1, [pscustomobject]@{ Number=$selectedIndex + 2; Start=ConvertTo-SrtTimestamp $split; End=$originalEnd; Text=$secondText })
                    for ($i=0;$i -lt $entries.Count;$i++) { $entries[$i].Number=$i+1 }
                    $grid.Items.Refresh(); $grid.SelectedIndex=$selectedIndex + 1; $grid.ScrollIntoView($grid.SelectedItem)
                    $editorStatus.Text = 'Caption split at the playback position.'
                    Update-LiveCaptionText
                }
                catch { $editorStatus.Text = $_.Exception.Message }
            })
        $editor.FindName('MergeCaptionButton').Add_Click({
                if ($null -eq $grid.SelectedItem -or $grid.SelectedIndex -ge ($entries.Count - 1)) { $editorStatus.Text = 'Select a caption that has a following row.'; return }
                $selectedIndex = $grid.SelectedIndex
                $entry = $entries[$selectedIndex]
                $next = $entries[$selectedIndex + 1]
                $entry.End = [string]$next.End
                $entry.Text = (([string]$entry.Text).Trim() + ' ' + ([string]$next.Text).Trim()).Trim()
                $entries.RemoveAt($selectedIndex + 1)
                for ($i=0;$i -lt $entries.Count;$i++) { $entries[$i].Number=$i+1 }
                $grid.Items.Refresh(); $grid.SelectedIndex=$selectedIndex
                $editorStatus.Text = 'Caption merged with the following row.'
                Update-LiveCaptionText
            })
        $editor.FindName('ReplaceAllButton').Add_Click({
                $grid.CommitEdit([Windows.Controls.DataGridEditingUnit]::Cell, $true) | Out-Null
                $needle = $findText.Text
                if ([string]::IsNullOrEmpty($needle)) { $editorStatus.Text = 'Enter text to find.'; return }
                $count = 0
                foreach ($entry in $entries) {
                    $matches = [regex]::Matches([string]$entry.Text, [regex]::Escape($needle), [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
                    if ($matches -gt 0) {
                        $entry.Text = [regex]::Replace([string]$entry.Text, [regex]::Escape($needle), [string]$replaceText.Text, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
                        $count += $matches
                    }
                }
                $grid.Items.Refresh()
                $editorStatus.Text = "Replaced $count occurrence(s)."
                Update-LiveCaptionText
            })
        $editor.FindName('PreviewCaptionButton').Add_Click({
                if ($null -eq $grid.SelectedItem) { $editorStatus.Text = 'Select a caption first.'; return }
                try {
                    $time = ConvertFrom-SrtTimestamp ([string]$grid.SelectedItem.Start)
                    if (-not $isSingleVoiceover) { $editorStatus.Text = 'The player shows a different video. Preview this one from the queue to hear its captions.' }
                    elseif ($null -ne $PreviewMedia.Source) {
                        $PreviewMedia.Position = $time
                        $PreviewMedia.Play()
                        $PlayPauseButton.Content = 'Pause'
                        $editorStatus.Text = "Playing from $($grid.SelectedItem.Start)."
                    }
                    else { $editorStatus.Text = 'Generate a preview before using caption playback.' }
                }
                catch { $editorStatus.Text = $_.Exception.Message }
            })
        $editor.FindName('CancelEditorButton').Add_Click({ $editor.Close() })
        $editor.FindName('SaveEditorButton').Add_Click({
                try {
                    $grid.CommitEdit([Windows.Controls.DataGridEditingUnit]::Cell, $true) | Out-Null
                    $grid.CommitEdit([Windows.Controls.DataGridEditingUnit]::Row, $true) | Out-Null
                    Save-SrtEntries -Entries $entries -Path $captionPath
                    $script:CaptionEditorSaved = $true
                    $script:LiveCaptionCacheSignature = ''
                    $editor.Close()
                }
                catch { $editorStatus.Text = $_.Exception.Message }
            })
        # A normal modeless window plus a nested dispatcher frame keeps this
        # function's save/cleanup flow synchronous without disabling the main
        # player. The user can seek and tune the live overlay while typing.
        $editorFrame = [Windows.Threading.DispatcherFrame]::new()
        $previousPreviewEnabled = $PreviewButton.IsEnabled
        $previousFinalEnabled = $FinalButton.IsEnabled
        $previousGenerateEnabled = $GenerateCaptionsButton.IsEnabled
        # Nothing may render, or open a second editor, while captions are
        # half edited.
        $lockedWhileEditing = @($RenderAllButton, $BatchResumeButton, $SelectedCaptionsButton, $SelectedPreviewButton, $EmptyPreviewButton)
        $previousLockedEnabled = @($lockedWhileEditing | ForEach-Object { [bool]$_.IsEnabled })
        foreach ($control in $lockedWhileEditing) { $control.IsEnabled = $false }
        $EditCaptionsButton.IsEnabled = $false
        $PreviewButton.IsEnabled = $false
        $FinalButton.IsEnabled = $false
        $GenerateCaptionsButton.IsEnabled = $false
        $editor.Add_Closed({
                $editorLiveTimer.Stop()
                $editorFrame.Continue = $false
            })
        $editor.Show()
        [Windows.Threading.Dispatcher]::PushFrame($editorFrame)
        $script:CaptionEditorOpen = $false
        $EditCaptionsButton.IsEnabled = $true
        $PreviewButton.IsEnabled = $previousPreviewEnabled
        $FinalButton.IsEnabled = $previousFinalEnabled
        $GenerateCaptionsButton.IsEnabled = $previousGenerateEnabled
        for ($index = 0; $index -lt $lockedWhileEditing.Count; $index++) { $lockedWhileEditing[$index].IsEnabled = $previousLockedEnabled[$index] }
        $script:LiveCaptionOverrideEntries = $null
        $script:LiveCaptionCacheSignature = ''
        Refresh-LiveCaptionEntries
        Update-LiveCaptionText
        if ($script:CaptionEditorSaved) {
            if ($isSingleVoiceover) {
                $script:CaptionPath = $captionPath
                $CaptionStatusText.Text = "Captions edited and saved ($($entries.Count) entries)."
                if ((Get-ComboText $CaptionModeCombo) -in @('SRT only', 'Burned + SRT') -and $script:FinalOutputPath -and (Test-Path -LiteralPath $script:FinalOutputPath -PathType Leaf)) {
                    [void](Copy-SrtWithWordWrapping -SourcePath $captionPath -DestinationPath ([IO.Path]::ChangeExtension($script:FinalOutputPath, '.srt')) -MaxWordsPerLine ([int][Math]::Round($CaptionWordsPerLineSlider.Value)))
                }
            }
            $StatusText.Text = 'Caption changes saved.'
            Update-BatchInspector
        }
    }
    catch { Show-ErrorMessage $_.Exception.Message 'Caption editor' }
}

function Get-StableHash {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function Start-ResumableFinalRender {
    param(
        [psobject]$Settings,
        [string]$Fingerprint,
        [string]$DestinationPath,
        [string]$Encoder,
        [string]$AudioPath,
        [string]$WatermarkPath
    )
    $runId = [guid]::NewGuid().ToString('N')
    $runDirectory = Join-Path $script:DataRoot "final-run-$runId"
    New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
    $progressPath = Join-Path $runDirectory 'progress.txt'
    $errorPath = Join-Path $runDirectory 'render-error.log'
    $childPidPath = Join-Path $runDirectory 'child.pid'
    $jobPath = Join-Path $runDirectory 'render-job.json'
    $baseName = [IO.Path]::GetFileNameWithoutExtension($DestinationPath)
    $stagingPath = Join-Path (Split-Path -Parent $DestinationPath) ".$baseName.rendering-$runId.mp4"
    $filterBackendKey = if ($null -eq $script:FilterBackend) { 'cpu' } else { [string]$script:FilterBackend }
    $filterDeviceKey = if ($null -eq $script:FilterVulkanDeviceIndex) { -1 } else { [int]$script:FilterVulkanDeviceIndex }
    $resumeKey = Get-StableHash "$Fingerprint||$DestinationPath||$Encoder||$filterBackendKey||$filterDeviceKey||$($script:RenderPipelineVersion)"
    $resumeDirectory = Join-Path (Join-Path $script:DataRoot 'resume') $resumeKey
    $captionPath = if ($Settings.CaptionMode -ne 'Off') { [string]$script:CaptionPath } else { '' }
    $job = [ordered]@{
        FfmpegPath = $script:FfmpegPath
        FfprobePath = $script:FfprobePath
        EngineModulePath = Join-Path $script:AppRoot 'SlideshowEngine.psm1'
        PipelineVersion = $script:RenderPipelineVersion
        Timeline = $script:CurrentPlan
        AudioPath = $AudioPath
        WatermarkPath = $WatermarkPath
        DestinationPath = $DestinationPath
        StagingPath = $stagingPath
        PreviewPath = $script:PreviewPath
        # The preview video is caption-free; captions are a live WPF overlay.
        # A burned-caption final must therefore render its first segment.
        ReusePreview = ([bool]$script:PreviewValid -and [string]$Settings.CaptionMode -notin @('Burned only', 'Burned + SRT'))
        CaptionPath = $captionPath
        CaptionMode = [string]$Settings.CaptionMode
        Settings = $Settings
        Encoder = $Encoder
        VulkanDeviceIndex = if ($null -eq $script:VulkanDeviceIndex) { 0 } else { [int]$script:VulkanDeviceIndex }
        FilterBackend = if ($null -eq $script:FilterBackend) { 'cpu' } else { [string]$script:FilterBackend }
        FilterVulkanDeviceIndex = if ($null -eq $script:FilterVulkanDeviceIndex) { -1 } else { [int]$script:FilterVulkanDeviceIndex }
        OpenClDevice = if ($null -eq $script:OpenClDevice) { '' } else { [string]$script:OpenClDevice }
        ScreenKernelPath = $script:ScreenKernelPath
        ParallelSegments = Get-RecommendedParallelSegments -Encoder $Encoder
        SegmentSeconds = 30
        # YouTube plays back at about -14 LUFS and never raises a quiet upload.
        LoudnessTargetLufs = -14.0
        ResumeDirectory = $resumeDirectory
        ProgressPath = $progressPath
        ErrorPath = $errorPath
        ChildPidPath = $childPidPath
    }
    New-Item -ItemType Directory -Path $script:RenderJobsRoot -Force | Out-Null
    $historyEntry = Add-RenderHistoryEntry -Type Final -Name ([IO.Path]::GetFileNameWithoutExtension($DestinationPath)) -OutputPath $DestinationPath -Encoder $Encoder -ResumeDirectory $resumeDirectory
    $snapshotPath = Join-Path $script:RenderJobsRoot "$($historyEntry.Id).json"
    $historyEntry.JobSnapshotPath = $snapshotPath
    Save-RenderHistory
    $jobJson = $job | ConvertTo-Json -Depth 15
    [IO.File]::WriteAllText($jobPath, $jobJson, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($snapshotPath, $jobJson, [Text.UTF8Encoding]::new($false))
    $workerPath = Join-Path $script:AppRoot 'SlideshowRenderWorker.ps1'
    $argumentLine = Join-ProcessArguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$workerPath,'-JobPath',$jobPath)
    $script:CancelRequested = $false
    $script:RenderState = [pscustomobject]@{
        Kind = 'Final'
        IsWorker = $true
        RunDirectory = $runDirectory
        ProgressPath = $progressPath
        ErrorPath = $errorPath
        ChildPidPath = $childPidPath
        StagingPath = $stagingPath
        DestinationPath = $DestinationPath
        DurationSeconds = [double]$script:CurrentPlan.AudioDurationSeconds
        Fingerprint = $Fingerprint
        Encoder = $Encoder
        FilterBackend = if ($null -eq $script:FilterBackend) { 'cpu' } else { [string]$script:FilterBackend }
        CaptionPath = $captionPath
        ResumeDirectory = $resumeDirectory
        HistoryId = $historyEntry.Id
    }
    $RenderProgress.Value = 0
    $script:LastHistoryProgressBucket = -1
    $StatusText.Text = "Starting resumable final render with $Encoder..."
    Set-RenderControls $true
    $script:RenderProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentLine -PassThru -WindowStyle Hidden
    Write-ToolDiagnostic "Resumable final render started. Encoder=$Encoder FilterBackend=$($script:FilterBackend) PID=$($script:RenderProcess.Id)"
    $renderTimer.Start()
}

function Stop-RenderProcessTree {
    if ($null -eq $script:RenderProcess -or $script:RenderProcess.HasExited) { return }
    try {
        Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/PID', [string]$script:RenderProcess.Id, '/T', '/F') -Wait -WindowStyle Hidden | Out-Null
    }
    catch {
        try { $script:RenderProcess.Kill() } catch {}
    }
}

function Start-HistoryFinalResume {
    param([psobject]$HistoryEntry)
    if ($null -ne $script:RenderProcess -and -not $script:RenderProcess.HasExited) { throw 'Another render is already running.' }
    Assert-FFmpegAvailable
    $snapshotPath = [string]$HistoryEntry.JobSnapshotPath
    if ([string]::IsNullOrWhiteSpace($snapshotPath) -or -not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) {
        throw 'The saved render job is unavailable. Generate a preview and start a new final render.'
    }
    $job = [IO.File]::ReadAllText($snapshotPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($required in @([string]$job.AudioPath, [string]$job.WatermarkPath)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required media is missing:`r`n$required" }
    }
    foreach ($item in $job.Timeline.Items) {
        if (-not (Test-Path -LiteralPath ([string]$item.ImagePath) -PathType Leaf)) { throw "A source image is missing:`r`n$($item.ImagePath)" }
    }
    $destination = [string]$job.DestinationPath
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $destination) -PathType Container)) { throw 'The saved output folder no longer exists.' }
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        $choice = [Windows.MessageBox]::Show($window, "Render this video again and replace the existing output only after success?`r`n`r`n$destination", 'Confirm render', [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Question)
        if ($choice -ne [Windows.MessageBoxResult]::Yes) { return }
    }

    $encoder = Select-AvailableEncoder
    $filterBackend = Select-AvailableFilterBackend -Timeline $job.Timeline -Settings $job.Settings -WatermarkPath ([string]$job.WatermarkPath)
    $savedPipelineVersion = if ($job.PSObject.Properties['PipelineVersion']) { [string]$job.PipelineVersion } else { '' }
    $savedFilterBackend = if ($job.PSObject.Properties['FilterBackend']) { [string]$job.FilterBackend } else { 'cpu' }
    if ([string]$job.Encoder -ne $encoder -or $savedFilterBackend -ne $filterBackend -or $savedPipelineVersion -ne $script:RenderPipelineVersion) {
        $job.Encoder = $encoder
        if ($job.PSObject.Properties['PipelineVersion']) { $job.PipelineVersion = $script:RenderPipelineVersion }
        else { $job | Add-Member -NotePropertyName PipelineVersion -NotePropertyValue $script:RenderPipelineVersion }
        $resumeFilterDevice = if ($null -eq $script:FilterVulkanDeviceIndex) { -1 } else { [int]$script:FilterVulkanDeviceIndex }
        $newResumeKey = Get-StableHash "$($HistoryEntry.Id)||$destination||$encoder||$filterBackend||$resumeFilterDevice||$($script:RenderPipelineVersion)"
        $job.ResumeDirectory = Join-Path (Join-Path $script:DataRoot 'resume') $newResumeKey
        $HistoryEntry.ResumeDirectory = [string]$job.ResumeDirectory
    }
    if ($job.PSObject.Properties['FilterBackend']) { $job.FilterBackend = $filterBackend }
    else { $job | Add-Member -NotePropertyName FilterBackend -NotePropertyValue $filterBackend }
    $filterDevice = if ($null -eq $script:FilterVulkanDeviceIndex) { -1 } else { [int]$script:FilterVulkanDeviceIndex }
    if ($job.PSObject.Properties['FilterVulkanDeviceIndex']) { $job.FilterVulkanDeviceIndex = $filterDevice }
    else { $job | Add-Member -NotePropertyName FilterVulkanDeviceIndex -NotePropertyValue $filterDevice }
    if ($encoder -eq 'h264_vulkan') { $job.VulkanDeviceIndex = [int]$script:VulkanDeviceIndex }
    if ($encoder -eq 'h264_nvenc') {
        if ($job.PSObject.Properties['OpenClDevice']) { $job.OpenClDevice = [string]$script:OpenClDevice }
        else { $job | Add-Member -NotePropertyName OpenClDevice -NotePropertyValue ([string]$script:OpenClDevice) }
        if ($job.PSObject.Properties['ScreenKernelPath']) { $job.ScreenKernelPath = $script:ScreenKernelPath }
        else { $job | Add-Member -NotePropertyName ScreenKernelPath -NotePropertyValue $script:ScreenKernelPath }
    }
    # Concurrency is safe to re-evaluate on resume; it does not change how the
    # completed segments were cut, only how many render at once from here.
    $lanes = Get-RecommendedParallelSegments -Encoder $encoder
    if ($job.PSObject.Properties['ParallelSegments']) { $job.ParallelSegments = $lanes }
    else { $job | Add-Member -NotePropertyName ParallelSegments -NotePropertyValue $lanes }
    # Segment length must not change once a job has started. Its completed
    # segments were cut at the original length, and re-cutting mid-job would
    # silently discard every one of them.
    if (-not $job.PSObject.Properties['SegmentSeconds']) {
        $job | Add-Member -NotePropertyName SegmentSeconds -NotePropertyValue 30
    }
    $runId = [guid]::NewGuid().ToString('N')
    $runDirectory = Join-Path $script:DataRoot "history-run-$runId"
    New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
    $job.ProgressPath = Join-Path $runDirectory 'progress.txt'
    $job.ErrorPath = Join-Path $runDirectory 'render-error.log'
    $job.ChildPidPath = Join-Path $runDirectory 'child.pid'
    $job.StagingPath = Join-Path (Split-Path -Parent $destination) ".$([IO.Path]::GetFileNameWithoutExtension($destination)).resume-$runId.mp4"
    $job.ReusePreview = $false
    $job.PreviewPath = ''
    $jobPath = Join-Path $runDirectory 'render-job.json'
    $jobJson = $job | ConvertTo-Json -Depth 15
    [IO.File]::WriteAllText($jobPath, $jobJson, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($snapshotPath, $jobJson, [Text.UTF8Encoding]::new($false))
    $HistoryEntry.Status = 'Rendering'
    $HistoryEntry.Progress = 0
    $HistoryEntry.Encoder = $encoder
    $HistoryEntry.Detail = 'Resumed from render history.'
    $HistoryEntry.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    Save-RenderHistory
    $script:CancelRequested = $false
    $script:RenderState = [pscustomobject]@{
        Kind = 'Final'; IsWorker = $true; RunDirectory = $runDirectory
        ProgressPath = [string]$job.ProgressPath; ErrorPath = [string]$job.ErrorPath; ChildPidPath = [string]$job.ChildPidPath
        StagingPath = [string]$job.StagingPath; DestinationPath = $destination
        DurationSeconds = [double]$job.Timeline.AudioDurationSeconds; Fingerprint = ''; Encoder = $encoder; FilterBackend = $filterBackend
        CaptionPath = [string]$job.CaptionPath; ResumeDirectory = [string]$job.ResumeDirectory; HistoryId = [string]$HistoryEntry.Id
    }
    $RenderProgress.Value = 0
    $script:LastHistoryProgressBucket = -1
    Set-RenderControls $true
    $StatusText.Text = "Resuming $($HistoryEntry.Name)..."
    $workerPath = Join-Path $script:AppRoot 'SlideshowRenderWorker.ps1'
    $argumentLine = Join-ProcessArguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$workerPath,'-JobPath',$jobPath)
    $script:RenderProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentLine -PassThru -WindowStyle Hidden
    $renderTimer.Start()
}

function Remove-RenderHistorySnapshot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $root = [IO.Path]::GetFullPath($script:RenderJobsRoot).TrimEnd('\') + '\'
    $resolved = [IO.Path]::GetFullPath($Path)
    if ($resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Force -ErrorAction SilentlyContinue }
}

function Show-RenderHistory {
    trap {
        Write-ToolDiagnostic 'Render history window failed to open.' $_.Exception
        Show-ErrorMessage $_.Exception.Message 'Render History'
        return
    }
    Write-ToolDiagnostic 'Opening render history window.'
    $historyXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Render History" Width="1050" Height="650" MinWidth="820" MinHeight="500" WindowStartupLocation="CenterOwner"
        Background="#17171A" Foreground="White" FontFamily="Segoe UI">
    <Window.Resources>
        <!-- The grid was left on the stock Windows theme, which paints light
             headers, white row separators and a grey selector strip down the
             left. All of it had to be taken over explicitly. -->
        <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#E9E9E6"/></Style>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#26262B"/><Setter Property="Foreground" Value="#E9E9E6"/>
            <Setter Property="BorderBrush" Value="#41414A"/><Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="13,7"/><Setter Property="Margin" Value="3"/>
            <Setter Property="FontSize" Value="12.5"/><Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.84"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.45"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="DataGrid">
            <Setter Property="Background" Value="#101012"/>
            <Setter Property="Foreground" Value="#E9E9E6"/>
            <Setter Property="BorderBrush" Value="#33333A"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="RowBackground" Value="#1A1A1D"/>
            <Setter Property="AlternatingRowBackground" Value="#151517"/>
            <Setter Property="HorizontalGridLinesBrush" Value="#26262B"/>
            <Setter Property="VerticalGridLinesBrush" Value="Transparent"/>
            <Setter Property="GridLinesVisibility" Value="Horizontal"/>
            <Setter Property="HeadersVisibility" Value="Column"/>
            <Setter Property="RowHeight" Value="34"/>
            <Setter Property="FontSize" Value="12.5"/>
        </Style>
        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="#26262B"/>
            <Setter Property="Foreground" Value="#A3A39E"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="11,9"/>
            <Setter Property="BorderBrush" Value="#33333A"/>
            <Setter Property="BorderThickness" Value="0,0,1,1"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
        </Style>
        <Style TargetType="DataGridRow">
            <Setter Property="Background" Value="#1A1A1D"/>
            <Setter Property="Foreground" Value="#E9E9E6"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#232327"/></Trigger>
                <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#2A2119"/></Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="DataGridCell">
            <Setter Property="Foreground" Value="#E9E9E6"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <!-- The stock cell paints the system highlight when selected,
                         which is a white block in this window. -->
                    <ControlTemplate TargetType="DataGridCell">
                        <Border Background="Transparent" Padding="11,0">
                            <ContentPresenter VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <Grid Margin="14">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="92"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <StackPanel><TextBlock Text="Render History" FontSize="22" FontWeight="SemiBold"/><TextBlock Text="Completed, failed, paused, and resumable production jobs." Foreground="#7E7E7A" Margin="0,4,0,12"/></StackPanel>
        <DataGrid x:Name="HistoryGrid" Grid.Row="1" AutoGenerateColumns="False" CanUserAddRows="False" IsReadOnly="True" SelectionMode="Single"
                  CanUserResizeRows="False" SelectionUnit="FullRow">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="95"/>
                <DataGridTextColumn Header="Type" Binding="{Binding Type}" Width="70"/>
                <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="180"/>
                <DataGridTextColumn Header="Started" Binding="{Binding Started}" Width="145"/>
                <DataGridTextColumn Header="Progress" Binding="{Binding Progress}" Width="80"/>
                <DataGridTextColumn Header="Output" Binding="{Binding OutputPath}" Width="*"/>
            </DataGrid.Columns>
        </DataGrid>
        <Border Grid.Row="2" Background="#1E1E22" BorderBrush="#33333A" BorderThickness="1" CornerRadius="7" Padding="10" Margin="0,10">
            <TextBlock x:Name="HistoryDetails" Text="Select a render to see details." Foreground="#A3A39E" TextWrapping="Wrap"/>
        </Border>
        <Grid Grid.Row="3"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel Orientation="Horizontal"><Button x:Name="OpenHistoryOutputButton" Content="Open Output"/><Button x:Name="OpenHistoryFolderButton" Content="Open Folder"/><Button x:Name="RemoveHistoryButton" Content="Remove" Background="#5A3A38"/><Button x:Name="ClearCompletedButton" Content="Clear Completed"/></StackPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal"><Button x:Name="CloseHistoryButton" Content="Close"/><Button x:Name="ResumeHistoryButton" Content="Resume Selected" Background="#E0913F" BorderBrush="#E0913F" FontWeight="SemiBold"/></StackPanel>
        </Grid>
    </Grid>
</Window>
'@
    $reader = [Xml.XmlNodeReader]::new([xml]$historyXaml)
    $historyWindow = [Windows.Markup.XamlReader]::Load($reader)
    $historyWindow.Owner = $window
    Set-WindowIcon -Target $historyWindow
    $historyWindow.Add_SourceInitialized({ try { $handle = [Windows.Interop.WindowInteropHelper]::new($historyWindow).Handle; $enabled = 1; [void][CreatorFlowWindowTheme]::DwmSetWindowAttribute($handle, 20, [ref]$enabled, 4) } catch {} })
    $grid = $historyWindow.FindName('HistoryGrid')
    $details = $historyWindow.FindName('HistoryDetails')

    $refresh = {
        $rows = [Collections.ObjectModel.ObservableCollection[object]]::new()
        foreach ($entry in @($script:RenderHistory | Sort-Object StartedUtc -Descending)) {
            $started = try { ([DateTime]::Parse([string]$entry.StartedUtc).ToLocalTime()).ToString('yyyy-MM-dd HH:mm') } catch { [string]$entry.StartedUtc }
            $rows.Add([pscustomobject]@{ EntryId = [string]$entry.Id; Status = [string]$entry.Status; Type = [string]$entry.Type; Name = [string]$entry.Name; Started = $started; Progress = "$([int]$entry.Progress)%"; OutputPath = [string]$entry.OutputPath })
        }
        $grid.ItemsSource = $rows
        $details.Text = if ($rows.Count -eq 0) { 'No final or batch renders have been recorded yet.' } else { 'Select a render to see details.' }
    }
    & $refresh
    $getSelectedEntry = {
        if ($null -eq $grid.SelectedItem) { return $null }
        return @($script:RenderHistory | Where-Object { [string]$_.Id -eq [string]$grid.SelectedItem.EntryId } | Select-Object -First 1)[0]
    }
    $grid.Add_SelectionChanged({
            $entry = & $getSelectedEntry
            if ($null -ne $entry) { $details.Text = "$($entry.Status) - $($entry.Detail)`r`nEncoder: $($entry.Encoder)`r`nOutput: $($entry.OutputPath)" }
        })
    $historyWindow.FindName('OpenHistoryOutputButton').Add_Click({ $entry = & $getSelectedEntry; if ($null -ne $entry -and (Test-Path -LiteralPath ([string]$entry.OutputPath) -PathType Leaf)) { Start-Process -FilePath ([string]$entry.OutputPath) } })
    $historyWindow.FindName('OpenHistoryFolderButton').Add_Click({ $entry = & $getSelectedEntry; if ($null -ne $entry) { $folder = Split-Path -Parent ([string]$entry.OutputPath); if (Test-Path -LiteralPath $folder -PathType Container) { Start-Process explorer.exe -ArgumentList ([string]$folder) } } })
    $historyWindow.FindName('RemoveHistoryButton').Add_Click({
            $entry = & $getSelectedEntry
            if ($null -eq $entry) { return }
            if ([string]$entry.Status -eq 'Rendering') { $details.Text = 'A running render cannot be removed.'; return }
            Remove-RenderHistorySnapshot ([string]$entry.JobSnapshotPath)
            $script:RenderHistory = @($script:RenderHistory | Where-Object { [string]$_.Id -ne [string]$entry.Id })
            Save-RenderHistory
            & $refresh
        })
    $historyWindow.FindName('ClearCompletedButton').Add_Click({
            foreach ($entry in @($script:RenderHistory | Where-Object { [string]$_.Status -eq 'Completed' })) { Remove-RenderHistorySnapshot ([string]$entry.JobSnapshotPath) }
            $script:RenderHistory = @($script:RenderHistory | Where-Object { [string]$_.Status -ne 'Completed' })
            Save-RenderHistory
            & $refresh
        })
    $historyWindow.FindName('CloseHistoryButton').Add_Click({ $historyWindow.Close() })
    $historyWindow.FindName('ResumeHistoryButton').Add_Click({
            $entry = & $getSelectedEntry
            if ($null -eq $entry) { $details.Text = 'Select a render first.'; return }
            if ($null -ne $script:RenderProcess -and -not $script:RenderProcess.HasExited) { $details.Text = 'Wait for the active render to finish or cancel it first.'; return }
            $script:HistoryResumeEntry = $entry
            $historyWindow.DialogResult = $true
            $historyWindow.Close()
        })
    $script:HistoryResumeEntry = $null
    [void]$historyWindow.ShowDialog()
    if ($null -ne $script:HistoryResumeEntry) {
        try {
            if ([string]$script:HistoryResumeEntry.Type -eq 'Batch') {
                Start-BatchRender -ProjectPaths @($script:HistoryResumeEntry.ProjectPaths) -HistoryId ([string]$script:HistoryResumeEntry.Id)
            }
            else { Start-HistoryFinalResume -HistoryEntry $script:HistoryResumeEntry }
        }
        catch { Show-ErrorMessage $_.Exception.Message 'Could not resume render' }
    }
}

function Test-VoiceoverFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    return $script:VoiceoverExtensions -contains ([IO.Path]::GetExtension($Path).ToLowerInvariant())
}

function Get-QueueOutputFileName {
    # A scanned queue row asks for a name, not a path. This turns what was typed
    # into the file name it will be saved as. Video titles carry colons and
    # question marks that Windows will not take in a file name, so they are
    # folded into dashes rather than refused - the row shows the name it settles
    # on while it is being typed, so nothing changes behind the person's back.
    param([string]$Name)
    $trimmed = ([string]$Name).Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return '' }
    $trimmed = $trimmed -replace '\s*:\s*', ' - '
    $trimmed = $trimmed -replace '[?*"<>|]', ''
    foreach ($forbidden in [IO.Path]::GetInvalidFileNameChars()) { $trimmed = $trimmed.Replace($forbidden, '-') }
    $trimmed = ($trimmed -replace '\s{2,}', ' ').Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return '' }
    if ([IO.Path]::GetExtension($trimmed).ToLowerInvariant() -ne '.mp4') { $trimmed = "$trimmed.mp4" }
    return $trimmed
}

function Resolve-QueueOutputPath {
    # A scanned row's Output box starts out holding its folder, ending in a
    # backslash, and the name is typed after it. Everything after the last
    # backslash is the name; everything before it is the folder. A bare name
    # with no backslash at all goes into the row's own folder. Returns the MP4
    # that comes to, or nothing while there is no usable name yet.
    #
    # Only a backslash separates. A forward slash inside a title ("AC/DC") is
    # part of the name and becomes a dash, rather than a folder that does not
    # exist.
    param([string]$Text, [string]$DefaultFolder)
    $typed = ([string]$Text).Trim()
    if ([string]::IsNullOrWhiteSpace($typed)) { return '' }
    $folder = $DefaultFolder
    $name = $typed
    $cut = $typed.LastIndexOf('\')
    if ($cut -ge 0) {
        $folder = $typed.Substring(0, $cut)
        $name = $typed.Substring($cut + 1)
        if ($folder -match '^[A-Za-z]:$') { $folder = "$folder\" }
    }
    $fileName = Get-QueueOutputFileName $name
    if ([string]::IsNullOrWhiteSpace($fileName) -or [string]::IsNullOrWhiteSpace($folder)) { return '' }
    try {
        if (-not [IO.Path]::IsPathRooted($folder)) { $folder = Join-Path $DefaultFolder $folder }
        return [IO.Path]::Combine($folder, $fileName)
    }
    catch {
        # Characters Windows refuses in a folder path; there is no file yet.
        return ''
    }
}

function Get-NaturalSortKey {
    # Folder 10 belongs after folder 9, and "2. Channel Two" after
    # "1. Channel One", which plain text sorting gets backwards.
    param([string]$Name)
    if ($Name -match '^\s*(\d+)') { return ('{0:D12} {1}' -f [long]$Matches[1], $Name) }
    return "zzzzzzzzzzzz $Name"
}

function Get-ChannelWatermarkPath {
    # One watermark per channel folder. When a channel folder holds several
    # videos, only a name saying "watermark" makes the choice unambiguous.
    param([string]$ChannelFolder)
    $videos = @(Get-ChildItem -LiteralPath $ChannelFolder -File -ErrorAction Stop | Where-Object { @('.mov', '.mp4') -contains $_.Extension.ToLowerInvariant() })
    if ($videos.Count -eq 0) { return [pscustomobject]@{ Path = ''; Reason = 'no MOV or MP4 watermark sits in the channel folder' } }
    if ($videos.Count -eq 1) { return [pscustomobject]@{ Path = $videos[0].FullName; Reason = '' } }
    $named = @($videos | Where-Object { $_.Name -match 'watermark' })
    if ($named.Count -eq 1) { return [pscustomobject]@{ Path = $named[0].FullName; Reason = '' } }
    return [pscustomobject]@{ Path = ''; Reason = "$($videos.Count) videos sit in the channel folder - keep one, or put 'watermark' in the name of the one to use" }
}

function Get-ChannelTitleKey {
    # Folder "01" and title line "1" are the same video. A folder that is not a
    # number is matched by its name instead.
    param([string]$Name)
    $trimmed = ([string]$Name).Trim()
    if ($trimmed -match '^\d+$') { return ([long]$trimmed).ToString() }
    return $trimmed.ToLowerInvariant()
}

function Get-ChannelNameKey {
    # Channel names are compared without case, spaces or punctuation, so a
    # heading typed as "star scope report" still finds "1. Star Scope Report".
    # Letters of every script are kept: some channel names are Japanese,
    # Korean or Persian.
    param([string]$Name)
    return (([string]$Name).ToLowerInvariant() -replace '[^\p{L}\p{N}]', '')
}

function Read-ChannelTitlesFile {
    # titles.txt sits in the channels folder beside the channel folders and
    # holds the day's video names, one heading per channel:
    #
    #   [1. Star Scope Report]
    #   1 = First video's title
    #   2 = Second video's title
    #
    # A heading is a line in square brackets, or starting with #. It may be the
    # channel's full folder name, its number alone, or its name alone. A title
    # line is the number of the video's folder, then = (or . ) : -), then the
    # title. Blank lines are ignored, and so is a number with nothing after it:
    # that is a template line not filled in yet, and the row is left to type.
    # Anything else is reported, not guessed at.
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    # Notepad saves UTF-8 nowadays, but an older ANSI file would otherwise turn
    # every curly apostrophe into junk. Strict UTF-8 refuses ANSI bytes, which
    # is how the two are told apart.
    try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) }
    catch { $text = [Text.Encoding]::Default.GetString($bytes) }
    $text = $text.TrimStart([char]0xFEFF)
    $sections = [Collections.Generic.List[object]]::new()
    $problems = [Collections.Generic.List[string]]::new()
    $current = $null
    $lineNumber = 0
    foreach ($line in ($text -split "`r?`n")) {
        $lineNumber++
        $trimmed = $line.Trim()
        if ($trimmed -eq '') { continue }
        $heading = $null
        if ($trimmed -match '^\[(.+)\]$') { $heading = $Matches[1].Trim() }
        elseif ($trimmed -match '^#+\s*(.+)$') { $heading = $Matches[1].Trim() }
        if ($null -ne $heading) {
            $current = [pscustomobject]@{ Heading = $heading; Line = $lineNumber; Titles = [ordered]@{} }
            $sections.Add($current)
            continue
        }
        if ($trimmed -notmatch '^(\d+)\s*[=.):\-]\s*(.*)$') { $problems.Add("titles.txt line $($lineNumber): not a [channel] heading or a 'number = title' line: $trimmed"); continue }
        $key = Get-ChannelTitleKey $Matches[1]
        $title = $Matches[2].Trim()
        if ($null -eq $current) { $problems.Add("titles.txt line $($lineNumber): this title comes before any [channel] heading"); continue }
        if ($title -eq '') { continue }
        if ($current.Titles.Contains($key)) { $problems.Add("titles.txt line $($lineNumber): video $key of [$($current.Heading)] is listed twice - the later title is used") }
        $current.Titles[$key] = $title
    }
    return [pscustomobject]@{ Sections = $sections.ToArray(); Problems = $problems.ToArray() }
}

function Find-ChannelForTitleHeading {
    # Returns the channel folder a titles.txt heading means, or nothing. The full
    # folder name wins, then the name without its number, then the number alone,
    # so "[1]", "[Star Scope Report]" and "[1. Star Scope Report]" all land on
    # "1. Star Scope Report".
    param([string]$Heading, [object[]]$Channels)
    $wanted = Get-ChannelNameKey $Heading
    $match = @($Channels | Where-Object { (Get-ChannelNameKey $_.Name) -eq $wanted })
    if ($match.Count -eq 1) { return $match[0] }
    $headingNumber = if ($Heading -match '^\s*(\d+)') { ([long]$Matches[1]).ToString() } else { '' }
    $headingName = Get-ChannelNameKey ($Heading -replace '^\s*\d+\s*[.)\-:]?\s*', '')
    if ($headingName -ne '') {
        $match = @($Channels | Where-Object { (Get-ChannelNameKey ($_.Name -replace '^\s*\d+\s*[.)\-:]?\s*', '')) -eq $headingName })
        if ($match.Count -eq 1) { return $match[0] }
    }
    if ($headingNumber -ne '') {
        $match = @($Channels | Where-Object { $_.Name -match '^\s*(\d+)' -and ([long]$Matches[1]).ToString() -eq $headingNumber })
        if ($match.Count -eq 1) { return $match[0] }
    }
    return $null
}

function Get-ChannelQueueScan {
    # Walks a folder of channel folders and pairs every numbered image folder
    # with the voiceover of the same name, which is the shape the channels are
    # kept in from day to day:
    #
    #   <root>\<channel>\<watermark>.mov
    #   <root>\<channel>\videos data\1\      <- that video's images
    #   <root>\<channel>\videos data\1.mp3   <- that video's voiceover
    #
    # Only the pairing is automatic. Whatever cannot be paired is reported back
    # instead of being dropped, because a folder with no voiceover beside it is
    # nearly always a mistake in the day's files rather than something to skip.
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) { throw "That folder does not exist:`r`n$Root" }
    $items = [Collections.Generic.List[object]]::new()
    $skipped = [Collections.Generic.List[string]]::new()
    $channels = @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction Stop | Sort-Object { Get-NaturalSortKey $_.Name })
    if ($channels.Count -eq 0) { throw "No channel folders were found in:`r`n$Root" }
    # The day's video names, if titles.txt is there, keyed by channel folder and
    # then by video folder. A heading that names no channel is reported, since
    # its titles would otherwise vanish without a word.
    $titlesByChannel = @{}
    $titlesUsed = @{}
    $titlesFile = @(Get-ChildItem -LiteralPath $Root -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq 'titles.txt' }) | Select-Object -First 1
    if ($null -ne $titlesFile) {
        $titles = Read-ChannelTitlesFile -Path $titlesFile.FullName
        foreach ($problem in $titles.Problems) { $skipped.Add($problem) }
        foreach ($section in $titles.Sections) {
            $channel = Find-ChannelForTitleHeading -Heading $section.Heading -Channels $channels
            if ($null -eq $channel) { $skipped.Add("titles.txt line $($section.Line): no channel folder matches [$($section.Heading)]"); continue }
            if (-not $titlesByChannel.ContainsKey($channel.FullName)) { $titlesByChannel[$channel.FullName] = @{} }
            foreach ($key in $section.Titles.Keys) { $titlesByChannel[$channel.FullName][$key] = [string]$section.Titles[$key] }
        }
    }
    foreach ($channel in $channels) {
        $watermark = Get-ChannelWatermarkPath -ChannelFolder $channel.FullName
        if ([string]::IsNullOrWhiteSpace($watermark.Path)) { $skipped.Add("$($channel.Name): $($watermark.Reason)"); continue }
        $dataFolders = @(Get-ChildItem -LiteralPath $channel.FullName -Directory | Where-Object { ($_.Name -replace '[\s_\-]', '').ToLowerInvariant() -eq 'videosdata' })
        # Falling back to the channel folder itself lets a channel that keeps its
        # numbered folders one level up still scan.
        $dataRoot = if ($dataFolders.Count -gt 0) { $dataFolders[0].FullName } else { $channel.FullName }
        # Finished videos are saved beside the day's data, in the videos data
        # folder itself. A channel without one keeps its data in the channel
        # folder, where a rendered MP4 would stand next to the watermark and
        # leave the next scan unable to tell which is which, so it gets a
        # Renders folder instead.
        $outputFolder = if ($dataFolders.Count -gt 0) { $dataFolders[0].FullName } else { Join-Path $channel.FullName 'Renders' }
        $audioByName = @{}
        foreach ($file in Get-ChildItem -LiteralPath $dataRoot -File) {
            if ($script:VoiceoverExtensions -notcontains $file.Extension.ToLowerInvariant()) { continue }
            $key = $file.BaseName.ToLowerInvariant()
            if (-not $audioByName.ContainsKey($key)) { $audioByName[$key] = $file.FullName }
        }
        $paired = @{}
        $folders = @(Get-ChildItem -LiteralPath $dataRoot -Directory |
            Where-Object { @('renders', 'videosdata') -notcontains ($_.Name -replace '[\s_\-]', '').ToLowerInvariant() } |
            Sort-Object { Get-NaturalSortKey $_.Name })
        foreach ($folder in $folders) {
            $key = $folder.Name.ToLowerInvariant()
            if (-not $audioByName.ContainsKey($key)) { $skipped.Add("$($channel.Name) \ $($folder.Name): no voiceover named $($folder.Name) beside it"); continue }
            $images = @(Get-ChildItem -LiteralPath $folder.FullName -File | Where-Object { @('.jpg', '.jpeg', '.png', '.webp') -contains $_.Extension.ToLowerInvariant() })
            if ($images.Count -eq 0) { $skipped.Add("$($channel.Name) \ $($folder.Name): the folder holds no JPG, PNG or WEBP images"); continue }
            $paired[$key] = $true
            $title = ''
            $titleKey = Get-ChannelTitleKey $folder.Name
            if ($titlesByChannel.ContainsKey($channel.FullName) -and $titlesByChannel[$channel.FullName].ContainsKey($titleKey)) {
                $title = [string]$titlesByChannel[$channel.FullName][$titleKey]
                $titlesUsed["$($channel.FullName)|$titleKey"] = $true
            }
            $items.Add([pscustomobject]@{
                Channel = $channel.Name
                Label = "$($channel.Name) - $($folder.Name)"
                ImageFolder = $folder.FullName
                AudioPath = $audioByName[$key]
                WatermarkPath = $watermark.Path
                OutputFolder = $outputFolder
                ImageCount = $images.Count
                Title = $title
            })
        }
        foreach ($key in @($audioByName.Keys | Sort-Object { Get-NaturalSortKey $_ })) {
            if ($paired.ContainsKey($key)) { continue }
            $skipped.Add("$($channel.Name): $([IO.Path]::GetFileName($audioByName[$key])) has no image folder named $key")
        }
        # A title with no video to go on is nearly always a typo in a number or
        # a folder that did not get copied, so it is said rather than dropped.
        if ($titlesByChannel.ContainsKey($channel.FullName)) {
            foreach ($key in @($titlesByChannel[$channel.FullName].Keys | Sort-Object { Get-NaturalSortKey $_ })) {
                if ($titlesUsed.ContainsKey("$($channel.FullName)|$key")) { continue }
                $skipped.Add("titles.txt: $($channel.Name) has a title for video $key, but no video $key was queued")
            }
        }
    }
    return [pscustomobject]@{ Items = $items.ToArray(); Skipped = $skipped.ToArray() }
}

# --- The batch queue --------------------------------------------------------
#
# The queue is the main page of the window. Each video in it carries its own
# image folder, voiceover, watermark and output, so one batch can mix channels
# that do not share a watermark. Motion, captions, backdrop and export quality
# are set once in the shared settings and apply to every video.
#
# Event handlers made here are plain script blocks rather than closures. They
# run at the window's own scope, where every function and control in this file
# can be reached, and they find their video through the Tag of the control that
# raised them. A closure would have needed its variables copied in one by one,
# which is what made Remove look dead in the old queue window.

function Test-JobActive {
    # True from the moment a preview, render, batch or caption job is set up
    # until it has been wrapped up. The render process itself starts a moment
    # after the controls are locked, so asking only about the process would
    # leave the queue editable for that moment.
    return ($null -ne $script:RenderState) -or ($null -ne $script:RenderProcess -and -not $script:RenderProcess.HasExited)
}

function ConvertTo-Visibility {
    param([bool]$Visible)
    if ($Visible) { return [Windows.Visibility]::Visible }
    return [Windows.Visibility]::Collapsed
}

function New-QueueRow {
    # Every property exists from the start: strict mode turns reading one that
    # was never set into an error.
    param(
        [string]$Channel = '', [string]$Label = '', [string]$ImageFolder = '', [string]$AudioPath = '',
        [string]$WatermarkPath = '', [string]$OutputFolder = '', [string]$Name = '', [int]$ImageCount = -1
    )
    return [pscustomobject]@{
        Id = [guid]::NewGuid().ToString('N')
        Channel = $Channel
        Label = $Label
        ImageFolder = $ImageFolder
        AudioPath = $AudioPath
        WatermarkPath = $WatermarkPath
        OutputFolder = $OutputFolder
        Name = $Name
        ImageCount = $ImageCount
        ImagesOk = $false
        AudioOk = $false
        WatermarkOk = $false
        Duration = 0.0
        DurationProbed = $false
        Done = $false
        DoneOutput = ''
        # The timeline a preview of this video was made with, so the batch can
        # render exactly what was approved instead of a fresh shuffle.
        PreviewPlan = $null
        PreviewPlanSignature = ''
        Problem = ''
        ProblemKind = ''
        Visual = $null
    }
}

function Get-QueueRow {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
    foreach ($row in $script:QueueRows) { if ([string]$row.Id -eq $Id) { return $row } }
    return $null
}

function Get-SelectedQueueRow {
    return Get-QueueRow -Id $script:SelectedQueueRowId
}

function Get-QueueRowNumber {
    param([psobject]$Row)
    return $script:QueueRows.IndexOf($Row) + 1
}

function Get-QueueRowTitle {
    param([psobject]$Row)
    $name = ([string]$Row.Name).Trim()
    if ($name -ne '') { return $name }
    if (-not [string]::IsNullOrWhiteSpace([string]$Row.Label)) { return "Untitled ($($Row.Label))" }
    return 'Untitled video'
}

function Get-QueueRowChannelKey {
    param([psobject]$Row)
    if ([string]::IsNullOrWhiteSpace([string]$Row.Channel)) { return '#hand' }
    return [string]$Row.Channel
}

function Get-QueueRowOutputPath {
    # The name is typed on its own and saved in the row's folder. A name typed
    # with a folder in front of it goes to that folder instead.
    param([psobject]$Row)
    $name = ([string]$Row.Name).Trim()
    if ($name -eq '') { return '' }
    return Resolve-QueueOutputPath -Text $name -DefaultFolder ([string]$Row.OutputFolder)
}

function Update-QueueRowFiles {
    # Only cheap checks: whether each path is there. Counting the photographs
    # happens with the thumbnail, off to the side, so a scan of forty folders
    # does not stall the window.
    param([psobject]$Row)
    $folder = [string]$Row.ImageFolder
    $Row.ImagesOk = (-not [string]::IsNullOrWhiteSpace($folder)) -and (Test-Path -LiteralPath $folder -PathType Container)
    $Row.AudioOk = Test-VoiceoverFile ([string]$Row.AudioPath)
    $watermark = [string]$Row.WatermarkPath
    $Row.WatermarkOk = (-not [string]::IsNullOrWhiteSpace($watermark)) -and
        (Test-Path -LiteralPath $watermark -PathType Leaf) -and
        (@('.mov', '.mp4') -contains [IO.Path]::GetExtension($watermark).ToLowerInvariant())
}

function Get-QueueRowProblem {
    # What still stands between this video and Render all, in the words the
    # status column shows. Kind decides the colour: ok, warn (something to
    # type or choose) or bad (a file that is not there).
    param([psobject]$Row)
    if ([bool]$Row.Done) { return [pscustomobject]@{ Kind = 'done'; Text = 'Done' } }
    if (-not [bool]$Row.ImagesOk) { return [pscustomobject]@{ Kind = 'bad'; Text = 'Image folder missing' } }
    if ([int]$Row.ImageCount -eq 0) { return [pscustomobject]@{ Kind = 'bad'; Text = 'No images in folder' } }
    if (-not [bool]$Row.AudioOk) { return [pscustomobject]@{ Kind = 'bad'; Text = 'Voiceover missing' } }
    if (-not [bool]$Row.WatermarkOk) { return [pscustomobject]@{ Kind = 'bad'; Text = 'Watermark missing' } }
    $name = ([string]$Row.Name).Trim()
    if ($name -eq '') { return [pscustomobject]@{ Kind = 'warn'; Text = 'Needs a name' } }
    if ([string]::IsNullOrWhiteSpace((Get-QueueRowOutputPath -Row $Row))) {
        if ([string]::IsNullOrWhiteSpace([string]$Row.OutputFolder)) { return [pscustomobject]@{ Kind = 'warn'; Text = 'Choose a folder' } }
        return [pscustomobject]@{ Kind = 'warn'; Text = 'Name not usable' }
    }
    return [pscustomobject]@{ Kind = 'ok'; Text = 'Ready' }
}

function New-QueueIconButton {
    param([string]$Data, [string]$ToolTip, [string]$Tag, [bool]$Filled = $false)
    $path = [Windows.Shapes.Path]::new()
    $path.Data = [Windows.Media.Geometry]::Parse($Data)
    if ($Filled) { $path.Fill = $script:DimBrush }
    else {
        $path.Stroke = $script:DimBrush
        $path.StrokeThickness = 1.5
    }
    $path.HorizontalAlignment = 'Center'
    $path.VerticalAlignment = 'Center'
    $button = [Windows.Controls.Button]::new()
    $button.Style = $window.FindResource('QuietButtonStyle')
    $button.Content = $path
    $button.Width = 28
    $button.Height = 28
    $button.Padding = [Windows.Thickness]::new(0)
    $button.Margin = [Windows.Thickness]::new(2, 0, 0, 0)
    $button.ToolTip = $ToolTip
    $button.Tag = $Tag
    return $button
}

function New-QueueCellText {
    param([int]$Column, [Windows.Media.Brush]$Foreground, [double]$FontSize = 12.5)
    $text = [Windows.Controls.TextBlock]::new()
    $text.Foreground = $Foreground
    $text.FontSize = $FontSize
    $text.TextTrimming = 'CharacterEllipsis'
    $text.VerticalAlignment = 'Center'
    [Windows.Controls.Grid]::SetColumn($text, $Column)
    return $text
}

function New-StatusPill {
    param([int]$Column = -1)
    $dot = [Windows.Shapes.Ellipse]::new()
    $dot.Width = 6
    $dot.Height = 6
    $dot.Margin = [Windows.Thickness]::new(0, 0, 6, 0)
    $dot.VerticalAlignment = 'Center'
    $label = [Windows.Controls.TextBlock]::new()
    $label.FontSize = 11.5
    $label.VerticalAlignment = 'Center'
    $label.TextTrimming = 'CharacterEllipsis'
    $stack = [Windows.Controls.StackPanel]::new()
    $stack.Orientation = 'Horizontal'
    [void]$stack.Children.Add($dot)
    [void]$stack.Children.Add($label)
    $pill = [Windows.Controls.Border]::new()
    $pill.CornerRadius = [Windows.CornerRadius]::new(11)
    $pill.Padding = [Windows.Thickness]::new(9, 3, 10, 3)
    $pill.HorizontalAlignment = 'Left'
    $pill.VerticalAlignment = 'Center'
    $pill.Child = $stack
    if ($Column -ge 0) { [Windows.Controls.Grid]::SetColumn($pill, $Column) }
    return [pscustomobject]@{ Border = $pill; Dot = $dot; Text = $label }
}

function Set-StatusPill {
    param([psobject]$Pill, [string]$Kind, [string]$Text)
    switch ($Kind) {
        { $_ -in @('ok', 'done') } { $foreground = $script:OkTextBrush; $background = $script:OkTintBrush }
        'warn' { $foreground = $script:AccentBrush; $background = $script:AccentTintBrush }
        'bad' { $foreground = $script:BadBrush; $background = $script:BadTintBrush }
        default { $foreground = $script:DimBrush; $background = $script:RaisedBrush }
    }
    $Pill.Border.Background = $background
    $Pill.Dot.Fill = $foreground
    $Pill.Text.Foreground = $foreground
    $Pill.Text.Text = $Text
}

function New-QueueColumns {
    param([Windows.Controls.Grid]$Grid, [int[]]$Widths)
    # A negative width is the one column that takes what is left.
    foreach ($width in $Widths) {
        $column = [Windows.Controls.ColumnDefinition]::new()
        $column.Width = if ($width -lt 0) { [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star) } else { [Windows.GridLength]::new($width) }
        $Grid.ColumnDefinitions.Add($column)
    }
}

function New-QueueRowVisual {
    # One line of the queue table. Its columns match the header in the window.
    param([psobject]$Row)
    $border = [Windows.Controls.Border]::new()
    $border.Tag = [string]$Row.Id
    $border.BorderBrush = $script:RowLineBrush
    $border.BorderThickness = [Windows.Thickness]::new(0, 0, 0, 1)
    $border.Padding = [Windows.Thickness]::new(12, 0, 12, 0)
    $border.Height = 54
    $border.Background = $script:TransparentBrush
    $grid = [Windows.Controls.Grid]::new()
    New-QueueColumns -Grid $grid -Widths @(30, 66, -1, 140, 64, 68, 142, 70)
    $border.Child = $grid

    $number = New-QueueCellText -Column 0 -Foreground $script:MutedBrush -FontSize 12
    [void]$grid.Children.Add($number)

    $thumbImage = [Windows.Controls.Image]::new()
    $thumbImage.Stretch = 'UniformToFill'
    [Windows.Media.RenderOptions]::SetBitmapScalingMode($thumbImage, [Windows.Media.BitmapScalingMode]::HighQuality)
    $thumbHost = [Windows.Controls.Border]::new()
    $thumbHost.Width = 56
    $thumbHost.Height = 32
    $thumbHost.CornerRadius = [Windows.CornerRadius]::new(4)
    $thumbHost.Background = $script:ThumbFillBrush
    $thumbHost.BorderBrush = New-ToolBrush '#3A3A42'
    $thumbHost.BorderThickness = [Windows.Thickness]::new(1)
    $thumbHost.ClipToBounds = $true
    $thumbHost.HorizontalAlignment = 'Left'
    $thumbHost.Child = $thumbImage
    [Windows.Controls.Grid]::SetColumn($thumbHost, 1)
    [void]$grid.Children.Add($thumbHost)

    $nameBox = [Windows.Controls.TextBox]::new()
    $nameBox.Tag = [string]$Row.Id
    $nameBox.Text = [string]$Row.Name
    # Sized by its text rather than fixed. A title with accents, Thai, Korean
    # or an emoji is drawn in a fallback font with a taller line, and a fixed
    # 32 px box cut those titles in half or scrolled them out of sight.
    $nameBox.MinHeight = 32
    $nameBox.Padding = [Windows.Thickness]::new(8, 4, 8, 4)
    $nameBox.VerticalContentAlignment = 'Center'
    [Windows.Controls.ScrollViewer]::SetVerticalScrollBarVisibility($nameBox, [Windows.Controls.ScrollBarVisibility]::Disabled)
    $nameBox.VerticalAlignment = 'Center'
    $nameBox.ToolTip = 'The video''s name. It is saved under this name in the folder shown in the panel on the right.'
    [Windows.Controls.Grid]::SetColumn($nameBox, 2)
    [void]$grid.Children.Add($nameBox)

    $channel = New-QueueCellText -Column 3 -Foreground $script:DimBrush -FontSize 12
    $channel.Margin = [Windows.Thickness]::new(10, 0, 8, 0)
    [void]$grid.Children.Add($channel)
    $images = New-QueueCellText -Column 4 -Foreground $script:DimBrush -FontSize 12
    [void]$grid.Children.Add($images)
    $length = New-QueueCellText -Column 5 -Foreground $script:DimBrush -FontSize 12
    [void]$grid.Children.Add($length)

    $pill = New-StatusPill -Column 6
    [void]$grid.Children.Add($pill.Border)

    $actions = [Windows.Controls.StackPanel]::new()
    $actions.Orientation = 'Horizontal'
    $actions.HorizontalAlignment = 'Right'
    $actions.VerticalAlignment = 'Center'
    [Windows.Controls.Grid]::SetColumn($actions, 7)
    $previewButton = New-QueueIconButton -Data 'M0,0 L8,5 L0,10 Z' -ToolTip 'Preview 60 seconds of this video' -Tag ([string]$Row.Id) -Filled $true
    $openButton = New-QueueIconButton -Data 'M0.5,1.5 L4.5,1.5 L6,3 L11.5,3 L11.5,9.5 L0.5,9.5 Z' -ToolTip 'Show the finished video in its folder' -Tag ([string]$Row.Id)
    $removeButton = New-QueueIconButton -Data 'M0,0 L8,8 M8,0 L0,8' -ToolTip 'Remove from the queue' -Tag ([string]$Row.Id)
    [void]$actions.Children.Add($previewButton)
    [void]$actions.Children.Add($openButton)
    [void]$actions.Children.Add($removeButton)
    [void]$grid.Children.Add($actions)

    $border.Add_MouseLeftButtonDown({ param($sender, $eventArgs) Select-QueueRow -Id ([string]$sender.Tag) })
    $nameBox.Add_GotKeyboardFocus({ param($sender, $eventArgs) if ($script:SelectedQueueRowId -ne [string]$sender.Tag) { Select-QueueRow -Id ([string]$sender.Tag) } })
    $nameBox.Add_TextChanged({ param($sender, $eventArgs) Set-QueueRowName -Id ([string]$sender.Tag) -Name ([string]$sender.Text) })
    $previewButton.Add_Click({ param($sender, $eventArgs) Start-QueueRowPreview -Id ([string]$sender.Tag) })
    $openButton.Add_Click({ param($sender, $eventArgs) $target = Get-QueueRow -Id ([string]$sender.Tag); if ($null -ne $target) { Open-OutputInFolder -Path ([string]$target.DoneOutput) } })
    $removeButton.Add_Click({ param($sender, $eventArgs) Remove-QueueRow -Id ([string]$sender.Tag) })

    return [pscustomobject]@{
        Border = $border; Number = $number; Thumb = $thumbImage; NameBox = $nameBox
        Channel = $channel; Images = $images; Length = $length; Pill = $pill
        PreviewButton = $previewButton; OpenButton = $openButton; RemoveButton = $removeButton
    }
}

function Update-QueueRowCells {
    param([psobject]$Row)
    $visual = $Row.Visual
    if ($null -eq $visual) { return }
    if ([string]::IsNullOrWhiteSpace([string]$Row.Channel)) {
        $visual.Channel.Text = 'Added by hand'
        $visual.Channel.Foreground = $script:MutedBrush
    }
    else {
        $visual.Channel.Text = [string]$Row.Channel
        $visual.Channel.Foreground = $script:DimBrush
    }
    $visual.Channel.ToolTip = [string]$Row.Label
    $visual.Images.Text = if ([int]$Row.ImageCount -ge 0) { [string]$Row.ImageCount } else { '-' }
    $visual.Length.Text = if ([double]$Row.Duration -gt 0) { Format-Clock ([double]$Row.Duration) } else { '-' }
}

function Add-QueueRow {
    param([psobject]$Row, [switch]$Deferred)
    $Row.Visual = New-QueueRowVisual -Row $Row
    $script:QueueRows.Add($Row)
    [void]$QueueRowsPanel.Children.Add($Row.Visual.Border)
    Update-QueueRowFiles -Row $Row
    Update-QueueRowCells -Row $Row
    Request-QueueThumbnail -Row $Row
    if (-not $Deferred) { Complete-QueueChange }
}

function Complete-QueueChange {
    # Everything that depends on which videos are in the queue, redrawn once
    # after a change rather than after every row of a scan.
    param([bool]$Save = $true)
    Update-QueueNumbers
    Update-ChannelFilter
    Update-QueueStatuses
    Update-QueueRowVisibility
    Update-QueueEditing
    Update-BatchHeader
    Update-BatchFooter
    Start-QueueDurationProbe
    if ($Save) { Save-QueueState }
}

function Update-QueueNumbers {
    for ($index = 0; $index -lt $script:QueueRows.Count; $index++) {
        $row = $script:QueueRows[$index]
        if ($null -ne $row.Visual) { $row.Visual.Number.Text = [string]($index + 1) }
    }
}

function Update-QueueStatuses {
    # Two videos writing one file would leave a video of the day missing, and
    # the batch would only find out after rendering both, so that is a status
    # here too.
    $claimed = @{}
    for ($index = 0; $index -lt $script:QueueRows.Count; $index++) {
        $row = $script:QueueRows[$index]
        $problem = Get-QueueRowProblem -Row $row
        $output = ''
        if ($problem.Kind -eq 'ok') {
            $output = Get-QueueRowOutputPath -Row $row
            $key = $output.ToLowerInvariant()
            if ($claimed.ContainsKey($key)) { $problem = [pscustomobject]@{ Kind = 'bad'; Text = "Same name as #$($claimed[$key])" } }
            else { $claimed[$key] = $index + 1 }
        }
        $row.Problem = [string]$problem.Text
        $row.ProblemKind = [string]$problem.Kind
        if ($null -ne $row.Visual) {
            Set-StatusPill -Pill $row.Visual.Pill -Kind $row.ProblemKind -Text $row.Problem
            $row.Visual.Pill.Border.ToolTip = if ($row.ProblemKind -eq 'ok') { "Saves as $output" }
                elseif ($row.ProblemKind -eq 'done') { [string]$row.DoneOutput }
                else { $null }
        }
    }
}

function Update-QueueRowVisibility {
    foreach ($row in $script:QueueRows) {
        if ($null -eq $row.Visual) { continue }
        $visible = ($script:ChannelFilter -eq '*') -or ((Get-QueueRowChannelKey -Row $row) -eq $script:ChannelFilter)
        $row.Visual.Border.Visibility = ConvertTo-Visibility $visible
    }
}

function Update-ChannelFilter {
    # The channels in the queue, in the order they were scanned, each with how
    # many of its videos are queued. Picking one narrows the table to it.
    $order = [Collections.Generic.List[string]]::new()
    $counts = @{}
    foreach ($row in $script:QueueRows) {
        $key = Get-QueueRowChannelKey -Row $row
        if (-not $counts.ContainsKey($key)) { $counts[$key] = 0; $order.Add($key) }
        $counts[$key] = [int]$counts[$key] + 1
    }
    # Videos added by hand are listed after the channels.
    if ($order.Contains('#hand')) { [void]$order.Remove('#hand'); $order.Add('#hand') }
    if ($script:ChannelFilter -ne '*' -and -not $counts.ContainsKey($script:ChannelFilter)) { $script:ChannelFilter = '*' }

    $ChannelFilterPanel.Children.Clear()
    $entries = @([pscustomobject]@{ Key = '*'; Label = 'All videos'; Count = $script:QueueRows.Count })
    foreach ($key in $order) {
        $label = if ($key -eq '#hand') { 'Added by hand' } else { $key }
        $entries += [pscustomobject]@{ Key = $key; Label = $label; Count = [int]$counts[$key] }
    }
    foreach ($entry in $entries) {
        $isActive = ($entry.Key -eq $script:ChannelFilter)
        $label = [Windows.Controls.TextBlock]::new()
        $label.Text = [string]$entry.Label
        $label.FontSize = 13
        $label.TextTrimming = 'CharacterEllipsis'
        $label.FontWeight = if ($isActive) { 'SemiBold' } else { 'Normal' }
        $count = [Windows.Controls.TextBlock]::new()
        $count.Text = [string]$entry.Count
        $count.FontSize = 11
        $count.Foreground = $script:DimBrush
        $count.Margin = [Windows.Thickness]::new(8, 0, 0, 0)
        [Windows.Controls.Grid]::SetColumn($count, 1)
        $grid = [Windows.Controls.Grid]::new()
        New-QueueColumns -Grid $grid -Widths @(-1, 0)
        $grid.ColumnDefinitions[1].Width = [Windows.GridLength]::Auto
        [void]$grid.Children.Add($label)
        [void]$grid.Children.Add($count)
        $button = [Windows.Controls.Button]::new()
        $button.Style = $window.FindResource('StepButtonStyle')
        $button.Content = $grid
        $button.Tag = [string]$entry.Key
        $button.ToolTip = if ($entry.Key -eq '#hand') { 'Videos added one at a time with + Add video' } else { $null }
        $button.Background = if ($isActive) { $script:AccentTintBrush } else { $script:TransparentBrush }
        $button.BorderBrush = if ($isActive) { $script:AccentDeepBrush } else { $script:TransparentBrush }
        $button.Add_Click({ param($sender, $eventArgs) Set-ChannelFilter -Key ([string]$sender.Tag) })
        [void]$ChannelFilterPanel.Children.Add($button)
    }
}

function Set-ChannelFilter {
    param([string]$Key)
    $script:ChannelFilter = $Key
    Update-ChannelFilter
    Update-QueueRowVisibility
}

function Update-QueueEditing {
    # Nothing in the queue changes under a running render, and a finished
    # video keeps the name it was saved under.
    $busy = Test-JobActive
    $run = $script:BatchRun
    $showRun = ($null -ne $run)
    $QueueTableHost.Visibility = ConvertTo-Visibility (-not $showRun)
    $RenderTableHost.Visibility = ConvertTo-Visibility $showRun
    $QueueActionsPanel.Visibility = ConvertTo-Visibility (-not $showRun)
    $ShowQueueButton.Visibility = ConvertTo-Visibility ($showRun -and -not [bool]$run.Running)
    $DefaultWatermarkRow.Visibility = ConvertTo-Visibility (-not $showRun)
    $ScanSummaryBorder.Visibility = ConvertTo-Visibility ((-not $showRun) -and -not [string]::IsNullOrWhiteSpace($ScanSummaryText.Text))
    $QueueEmptyPanel.Visibility = ConvertTo-Visibility ($script:QueueRows.Count -eq 0)
    $ClearFinishedButton.Visibility = ConvertTo-Visibility (@($script:QueueRows | Where-Object { [bool]$_.Done }).Count -gt 0)
    foreach ($row in $script:QueueRows) {
        $visual = $row.Visual
        if ($null -eq $visual) { continue }
        $isDone = [bool]$row.Done
        $visual.NameBox.IsReadOnly = $busy -or $isDone
        $visual.NameBox.Foreground = if ($isDone) { $script:DimBrush } else { $script:TextBrush }
        $visual.PreviewButton.Visibility = ConvertTo-Visibility (-not $isDone)
        $visual.PreviewButton.IsEnabled = -not $busy
        $visual.OpenButton.Visibility = ConvertTo-Visibility $isDone
        $visual.RemoveButton.IsEnabled = -not $busy
    }
    foreach ($box in @($SelectedNameText, $SelectedOutputFolderText, $SelectedImagesText, $SelectedAudioText, $SelectedWatermarkText)) {
        $box.IsReadOnly = $busy
    }
    foreach ($button in @($SelectedOutputBrowseButton, $SelectedImagesBrowseButton, $SelectedAudioBrowseButton, $SelectedWatermarkBrowseButton)) {
        $button.IsEnabled = -not $busy
    }
}

function Update-BatchHeader {
    $run = $script:BatchRun
    if ($null -ne $run) {
        $items = @($run.Items)
        $done = @($items | Where-Object { $_.State -eq 'Done' }).Count
        $active = @($items | Where-Object { $_.State -eq 'Rendering' }).Count
        $waiting = @($items | Where-Object { $_.State -eq 'Queued' }).Count
        $stopped = @($items | Where-Object { $_.State -in @('Paused', 'Failed') }).Count
        $BatchHeadingText.Text = if ([bool]$run.Running) { 'Rendering the batch' }
            elseif ($run.Result -eq 'Completed') { 'Batch finished' }
            elseif ($run.Result -eq 'Paused') { 'Batch paused' }
            else { 'Batch stopped' }
        $parts = @("$done of $($items.Count) finished")
        if ($active -gt 0) { $parts += 'one rendering' }
        if ($waiting -gt 0) { $parts += "$waiting waiting" }
        if ($stopped -gt 0) { $parts += "$stopped stopped" }
        $BatchSubheadingText.Text = $parts -join ', '
        return
    }
    $BatchHeadingText.Text = "Today's queue"
    $total = $script:QueueRows.Count
    if ($total -eq 0) {
        $BatchSubheadingText.Text = 'Scan your channels folder to queue the day''s videos.'
        return
    }
    $channels = @($script:QueueRows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Channel) } | ForEach-Object { [string]$_.Channel } | Sort-Object -Unique).Count
    $finished = @($script:QueueRows | Where-Object { [bool]$_.Done }).Count
    $text = if ($total -eq 1) { '1 video' } else { "$total videos" }
    if ($channels -eq 1) { $text += ' from 1 channel folder' }
    elseif ($channels -gt 1) { $text += " from $channels channel folders" }
    if ($finished -gt 0) { $text += ", $finished finished" }
    if ($channels -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$script:LastChannelsRoot)) { $text += "   -   $($script:LastChannelsRoot)" }
    $BatchSubheadingText.Text = $text
}

function Select-QueueRow {
    param([string]$Id)
    $script:SelectedQueueRowId = $Id
    foreach ($row in $script:QueueRows) {
        if ($null -eq $row.Visual) { continue }
        $row.Visual.Border.Background = if ([string]$row.Id -eq $Id) { $script:RaisedBrush } else { $script:TransparentBrush }
    }
    # Picking a video means looking at it, so the shared settings step aside.
    if (-not [string]::IsNullOrWhiteSpace($script:BatchSettingsSection)) {
        $script:BatchSettingsSection = ''
        Update-BatchNavHighlight
    }
    Update-BatchInspector
}

function Set-QueueRowName {
    param([string]$Id, [string]$Name)
    $row = Get-QueueRow -Id $Id
    if ($null -eq $row) { return }
    $row.Name = $Name
    if ($script:SelectedQueueRowId -eq $Id -and $SelectedNameText.Text -ne $Name) {
        $script:IsFillingInspector = $true
        try { $SelectedNameText.Text = $Name }
        finally { $script:IsFillingInspector = $false }
    }
    Update-QueueStatuses
    if ($script:SelectedQueueRowId -eq $Id) { Update-SelectedRowSummary -Row $row }
    Update-BatchFooter
}

function Set-SelectedQueueRowPath {
    # A path changed in the panel on the right, by typing or by Browse.
    param([ValidateSet('ImageFolder', 'AudioPath', 'WatermarkPath', 'OutputFolder')][string]$Field, [string]$Value)
    if ($script:IsFillingInspector) { return }
    $row = Get-SelectedQueueRow
    if ($null -eq $row) { return }
    $Value = ([string]$Value).Trim()
    if ([string]$row.$Field -eq $Value) { return }
    $row.$Field = $Value
    if ($Field -eq 'ImageFolder') {
        $row.ImageCount = -1
        $row.PreviewPlan = $null
        Request-QueueThumbnail -Row $row
    }
    elseif ($Field -eq 'AudioPath') {
        $row.Duration = 0.0
        $row.DurationProbed = $false
        $row.PreviewPlan = $null
    }
    Update-QueueRowFiles -Row $row
    Update-QueueRowCells -Row $row
    Update-QueueStatuses
    Update-SelectedRowSummary -Row $row
    Update-BatchFooter
    Start-QueueDurationProbe
}

function Remove-QueueRow {
    param([string]$Id)
    if (Test-JobActive) { return }
    $row = Get-QueueRow -Id $Id
    if ($null -eq $row) { return }
    $index = $script:QueueRows.IndexOf($row)
    [void]$script:QueueRows.Remove($row)
    if ($null -ne $row.Visual) { [void]$QueueRowsPanel.Children.Remove($row.Visual.Border) }
    if ($script:QueuePreviewRowId -eq $Id) { $script:QueuePreviewRowId = '' }
    if ($script:SelectedQueueRowId -eq $Id) {
        # The next video takes its place under the pointer, as a list does
        # when a line is deleted from it.
        $script:SelectedQueueRowId = ''
        if ($script:QueueRows.Count -gt 0) {
            $next = $script:QueueRows[[Math]::Min($index, $script:QueueRows.Count - 1)]
            $script:SelectedQueueRowId = [string]$next.Id
        }
    }
    Complete-QueueChange
    Select-QueueRow -Id $script:SelectedQueueRowId
}

function Clear-FinishedQueueRows {
    if (Test-JobActive) { return }
    foreach ($row in @($script:QueueRows | Where-Object { [bool]$_.Done })) {
        [void]$script:QueueRows.Remove($row)
        if ($null -ne $row.Visual) { [void]$QueueRowsPanel.Children.Remove($row.Visual.Border) }
        if ($script:SelectedQueueRowId -eq [string]$row.Id) { $script:SelectedQueueRowId = '' }
    }
    Complete-QueueChange
    Update-BatchInspector
}

function Add-QueueVideoByHand {
    # One video's image folder. Its voiceover is the audio file of the same name
    # beside the folder, the way channel folders are laid out, and the finished
    # video goes in that same folder until another is chosen.
    if (Test-JobActive) { return }
    $start = ''
    $selected = Get-SelectedQueueRow
    if ($null -ne $selected -and -not [string]::IsNullOrWhiteSpace([string]$selected.ImageFolder)) { $start = Split-Path -Parent ([string]$selected.ImageFolder) }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$script:LastChannelsRoot)) { $start = [string]$script:LastChannelsRoot }
    $picked = Select-Folder -Description 'Select the folder holding this video''s images' -InitialPath $start
    if ([string]::IsNullOrWhiteSpace($picked)) { return }
    $parent = Split-Path -Parent $picked
    $leaf = Split-Path -Leaf $picked
    $audio = ''
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        foreach ($extension in $script:VoiceoverExtensions) {
            $candidate = Join-Path $parent "$leaf$extension"
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $audio = $candidate; break }
        }
    }
    $row = New-QueueRow -Label $leaf -ImageFolder $picked -AudioPath $audio -WatermarkPath $BatchWatermarkText.Text.Trim() -OutputFolder $parent
    Add-QueueRow -Row $row
    Select-QueueRow -Id ([string]$row.Id)
    [void]$row.Visual.NameBox.Focus()
    if ([string]::IsNullOrWhiteSpace($audio)) {
        $StatusText.Text = "No voiceover named $leaf was found beside the folder. Choose it in the panel on the right."
    }
}

function Invoke-ChannelScan {
    # Pairs every numbered image folder in each channel folder with the
    # voiceover of the same name. A folder already in the queue is not added a
    # second time, so the same channels folder can be scanned again after
    # more of the day's files arrive.
    if (Test-JobActive) { return }
    try {
        $picked = Select-Folder -Description 'Select the folder that holds your channel folders' -InitialPath $script:LastChannelsRoot
        if ([string]::IsNullOrWhiteSpace($picked)) { return }
        $StatusText.Text = 'Scanning channel folders...'
        $window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
        $scan = Get-ChannelQueueScan -Root $picked
        $found = @($scan.Items)
        $ignored = @($scan.Skipped)
        $script:LastScanSkipped = $ignored
        $ScanSkippedButton.Content = "$($ignored.Count) skipped - why?"
        $ScanSkippedButton.Visibility = ConvertTo-Visibility ($ignored.Count -gt 0)
        if ($found.Count -eq 0) {
            $ScanSummaryText.Text = "Nothing could be queued from $picked."
            Update-QueueEditing
            Show-ErrorMessage ("Nothing in that folder could be queued:`r`n$picked`r`n`r`n" + ((@($ignored) | Select-Object -First 25) -join "`r`n")) 'Nothing to queue'
            return
        }
        $script:LastChannelsRoot = $picked
        $alreadyQueued = @{}
        foreach ($existing in $script:QueueRows) {
            if (-not [bool]$existing.Done) { $alreadyQueued[([string]$existing.ImageFolder).ToLowerInvariant()] = $true }
        }
        $added = [Collections.Generic.List[object]]::new()
        $skippedAsQueued = 0
        foreach ($item in $found) {
            if ($alreadyQueued.ContainsKey(([string]$item.ImageFolder).ToLowerInvariant())) { $skippedAsQueued++; continue }
            $row = New-QueueRow -Channel ([string]$item.Channel) -Label ([string]$item.Label) -ImageFolder ([string]$item.ImageFolder) `
                -AudioPath ([string]$item.AudioPath) -WatermarkPath ([string]$item.WatermarkPath) -OutputFolder ([string]$item.OutputFolder) `
                -Name ([string]$item.Title) -ImageCount ([int]$item.ImageCount)
            Add-QueueRow -Row $row -Deferred
            $added.Add($row)
        }
        Complete-QueueChange
        $channelCount = @($found | ForEach-Object { $_.Channel } | Sort-Object -Unique).Count
        $titled = @($added | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Name) }).Count
        if ($added.Count -eq 0) {
            $summary = "Every video in $picked is already in the queue."
        }
        elseif ($titled -eq $added.Count) { $summary = "Queued $($added.Count) video(s) from $channelCount channel folder(s), every one named from titles.txt. Check the names, then Render all." }
        elseif ($titled -gt 0) { $summary = "Queued $($added.Count) video(s) from $channelCount channel folder(s). titles.txt named $titled; type a name for the other $($added.Count - $titled), then Render all." }
        else { $summary = "Queued $($added.Count) video(s) from $channelCount channel folder(s). Type a name for each, then Render all." }
        if ($skippedAsQueued -gt 0 -and $added.Count -gt 0) { $summary += " $skippedAsQueued were already in the queue." }
        $ScanSummaryText.Text = $summary
        Update-QueueEditing
        Update-BatchHeader
        # The caret waits in the first box that still needs a name.
        $firstUnnamed = @($added | Where-Object { [string]::IsNullOrWhiteSpace(([string]$_.Name).Trim()) }) | Select-Object -First 1
        if ($null -eq $firstUnnamed -and $added.Count -gt 0) { $firstUnnamed = $added[0] }
        if ($null -ne $firstUnnamed) {
            Set-ChannelFilter -Key '*'
            Select-QueueRow -Id ([string]$firstUnnamed.Id)
            $firstUnnamed.Visual.Border.BringIntoView()
            [void]$firstUnnamed.Visual.NameBox.Focus()
            $firstUnnamed.Visual.NameBox.CaretIndex = $firstUnnamed.Visual.NameBox.Text.Length
        }
    }
    catch {
        Write-ToolDiagnostic 'Scanning the channels folder failed.' $_.Exception
        Show-ErrorMessage $_.Exception.Message 'Could not scan channels'
        Update-BatchFooter
    }
}

function Show-ScanSkipped {
    $skipped = @($script:LastScanSkipped)
    if ($skipped.Count -eq 0) { return }
    $shown = @($skipped | Select-Object -First 40)
    $text = $shown -join "`r`n"
    if ($skipped.Count -gt $shown.Count) { $text += "`r`n`r`n...and $($skipped.Count - $shown.Count) more." }
    Show-InfoMessage $text 'Skipped while scanning'
}

# --- Thumbnails and voiceover lengths, off to the side ----------------------

function Request-QueueThumbnail {
    param([psobject]$Row)
    $script:ThumbnailRequests.Enqueue([string]$Row.Id)
    $script:QueueTimer.Start()
}

function Update-QueueRowThumbnail {
    # Lists the image folder - which also counts the photographs - and shows
    # the first of them. Decoded small, so forty rows cost little memory.
    param([psobject]$Row)
    if ($null -eq $Row.Visual) { return }
    $Row.Visual.Thumb.Source = $null
    if ([bool]$Row.ImagesOk) {
        try {
            $files = @(Get-SupportedImageFiles -Folder ([string]$Row.ImageFolder))
            $Row.ImageCount = $files.Count
            if ($files.Count -gt 0) {
                $bitmap = [Windows.Media.Imaging.BitmapImage]::new()
                $bitmap.BeginInit()
                $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                $bitmap.DecodePixelWidth = 320
                $bitmap.UriSource = [uri]([string]$files[0])
                $bitmap.EndInit()
                $bitmap.Freeze()
                $Row.Visual.Thumb.Source = $bitmap
            }
        }
        catch {}
    }
    Update-QueueRowCells -Row $Row
    Update-QueueStatuses
    Update-BatchFooter
    if ($script:SelectedQueueRowId -eq [string]$Row.Id) { Update-BatchInspector }
}

function Start-QueueDurationProbe {
    # Voiceover lengths come from FFprobe, a fraction of a second each. Forty of
    # them on the interface thread would freeze the window for several seconds,
    # so they are measured on a runspace of their own, the way the update
    # check is.
    if ($null -ne $script:DurationProbe) { return }
    if ([string]::IsNullOrWhiteSpace([string]$script:FfprobePath)) { return }
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($row in $script:QueueRows) {
        if ([double]$row.Duration -gt 0 -or [bool]$row.DurationProbed -or -not [bool]$row.AudioOk) { continue }
        $row.DurationProbed = $true
        if (-not $paths.Contains([string]$row.AudioPath)) { $paths.Add([string]$row.AudioPath) }
    }
    if ($paths.Count -eq 0) { return }
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('ModulePath', (Join-Path $script:AppRoot 'SlideshowEngine.psm1'))
    $runspace.SessionStateProxy.SetVariable('ProbePath', [string]$script:FfprobePath)
    $runspace.SessionStateProxy.SetVariable('AudioPaths', $paths.ToArray())
    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    [void]$shell.AddScript({
        Import-Module $ModulePath -Force
        foreach ($audioPath in $AudioPaths) {
            $seconds = 0.0
            try { $seconds = [double](Get-MediaDurationSeconds -FfprobePath $ProbePath -MediaPath $audioPath) } catch {}
            [pscustomobject]@{ Path = $audioPath; Seconds = $seconds }
        }
    })
    $script:DurationProbe = [pscustomobject]@{ Shell = $shell; Runspace = $runspace; Handle = $shell.BeginInvoke() }
    $script:QueueTimer.Start()
    Update-BatchFooter
}

function Complete-QueueDurationProbe {
    $probe = $script:DurationProbe
    if ($null -eq $probe -or -not $probe.Handle.IsCompleted) { return }
    $script:DurationProbe = $null
    $results = @()
    try { $results = @($probe.Shell.EndInvoke($probe.Handle)) }
    catch { Write-ToolDiagnostic 'Measuring queued voiceovers failed.' $_.Exception }
    finally {
        $probe.Shell.Dispose()
        $probe.Runspace.Close()
        $probe.Runspace.Dispose()
    }
    $byPath = @{}
    foreach ($result in $results) {
        if ($null -ne $result -and [double]$result.Seconds -gt 0) { $byPath[([string]$result.Path).ToLowerInvariant()] = [double]$result.Seconds }
    }
    foreach ($row in $script:QueueRows) {
        $key = ([string]$row.AudioPath).ToLowerInvariant()
        if ($byPath.ContainsKey($key)) {
            $row.Duration = [double]$byPath[$key]
            Update-QueueRowCells -Row $row
        }
    }
    Update-BatchFooter
    # Videos added while these were being measured.
    Start-QueueDurationProbe
}

# --- Estimates ---------------------------------------------------------------

function Get-RenderSpeedEstimate {
    # Seconds of video rendered per second, for the chosen motion quality. A
    # finished batch on this computer replaces the starting figures, which are
    # the README's measurements at 24 FPS.
    $quality = Get-ComboText $MotionQualityCombo
    if ($script:RenderSpeeds.ContainsKey($quality) -and [double]$script:RenderSpeeds[$quality] -gt 0) { return [double]$script:RenderSpeeds[$quality] }
    switch ($quality) {
        'Fast' { return 2.8 }
        'Best' { return 1.35 }
        default { return 2.45 }
    }
}

function Format-LongDuration {
    param([double]$Seconds)
    if ($Seconds -lt 60) { return 'under a minute' }
    $totalMinutes = [int][Math]::Round($Seconds / 60.0)
    $hours = [int][Math]::Floor($totalMinutes / 60)
    $minutes = $totalMinutes - ($hours * 60)
    if ($hours -gt 0) { return ('{0} h {1:00} min' -f $hours, $minutes) }
    return "$minutes min"
}

function Get-QueueEstimateText {
    param([object[]]$Pending)
    $rows = @($Pending)
    if ($rows.Count -eq 0) { return '' }
    $known = @($rows | Where-Object { [double]$_.Duration -gt 0 })
    if ($known.Count -eq 0) {
        if ($null -ne $script:DurationProbe) { return 'measuring voiceovers...' }
        return ''
    }
    $quality = Get-ComboText $QualityCombo
    $videoSeconds = 0.0
    $megabytes = 0.0
    foreach ($row in $known) {
        $videoSeconds += [double]$row.Duration
        $megabytes += [double](Get-EstimatedOutputSizeMb -DurationSeconds ([double]$row.Duration) -Quality $quality)
    }
    $text = "about $(Format-LongDuration ($videoSeconds / (Get-RenderSpeedEstimate))), $(Format-ByteSize ($megabytes * 1MB))"
    if ($known.Count -lt $rows.Count) { $text += " (for $($known.Count) of $($rows.Count))" }
    return $text
}

# --- The panels around the queue ---------------------------------------------

function Update-BatchFooter {
    if ($script:IsLoading) { return }
    $run = $script:BatchRun
    $runRunning = ($null -ne $run) -and [bool]$run.Running
    $pending = @($script:QueueRows | Where-Object { -not [bool]$_.Done })
    $BatchCountText.Text = [string]$pending.Count
    $RenderAllButton.Visibility = ConvertTo-Visibility ($null -eq $run)
    $RenderAllButton.Content = if ($pending.Count -gt 0) { "Render all $($pending.Count)" } else { 'Render all' }
    $BatchPauseButton.Visibility = ConvertTo-Visibility $runRunning
    $BatchPauseButton.IsEnabled = $runRunning -and -not $script:CancelRequested
    $BatchResumeButton.Visibility = ConvertTo-Visibility (($null -ne $run) -and -not $runRunning -and ([string]$run.Result -in @('Paused', 'Failed')))
    $finalPath = [string]$script:FinalOutputPath
    $BatchOpenFolderButton.IsEnabled = (-not [string]::IsNullOrWhiteSpace($finalPath)) -and (Test-Path -LiteralPath $finalPath -PathType Leaf)
    $BatchEstimateText.Text = if ($null -eq $run) { Get-QueueEstimateText -Pending $pending } else { '' }

    # While a job runs, the status line is its progress.
    if ($script:AppMode -ne 'Batch' -or (Test-JobActive)) { return }
    $ReadinessPanel.Children.Clear()
    if ($null -ne $run) {
        $StatusText.Text = [string]$run.ResultText
        return
    }
    if ($pending.Count -eq 0) {
        $StatusText.Text = if ($script:QueueRows.Count -gt 0) { 'Every video in the queue is finished.' } else { 'The queue is empty.' }
        return
    }
    $ready = @($pending | Where-Object { $_.ProblemKind -eq 'ok' }).Count
    $StatusText.Text = "$ready of $($pending.Count) ready"
    # What is still missing, grouped, rather than a button with no reason.
    $groups = @($pending | Where-Object { $_.ProblemKind -ne 'ok' } | Group-Object -Property Problem | Sort-Object -Property Count -Descending)
    foreach ($group in ($groups | Select-Object -First 4)) {
        Add-ReadinessCheck -Label "$($group.Name) ($($group.Count))" -Done $false
    }
}

function Update-BatchNavHighlight {
    $buttons = @{ Motion = $BatchNavMotionButton; Captions = $BatchNavCaptionsButton; Blanking = $BatchNavBlankingButton; Export = $BatchNavExportButton }
    foreach ($key in $buttons.Keys) {
        $isActive = ($key -eq $script:BatchSettingsSection)
        $buttons[$key].Background = if ($isActive) { $script:AccentTintBrush } else { $script:TransparentBrush }
        $buttons[$key].BorderBrush = if ($isActive) { $script:AccentDeepBrush } else { $script:TransparentBrush }
    }
}

function Show-BatchSettings {
    # The shared settings open where the selected video's files were.
    param([string]$Name)
    $script:BatchSettingsSection = $Name
    Set-ActiveSection $Name
    Update-BatchNavHighlight
    Update-BatchInspector
}

function Hide-BatchSettings {
    $script:BatchSettingsSection = ''
    Update-BatchNavHighlight
    Update-BatchInspector
}

function Get-QueueCaptionNote {
    param([psobject]$Row)
    $mode = Get-ComboText $CaptionModeCombo
    if ($mode -eq 'Off') { return 'Captions are off for the batch. Turn them on under Captions in the left rail.' }
    if (-not [bool]$Row.AudioOk) { return 'Choose a voiceover to caption this video.' }
    try {
        $cachePath = Get-CaptionCachePath -AudioPath ([string]$Row.AudioPath) -DataRoot $script:DataRoot
        if (Test-Path -LiteralPath $cachePath -PathType Leaf) { return 'Captions are ready for this voiceover. Edit captions opens them to check or correct.' }
    }
    catch {}
    return 'Captions are generated from this voiceover when the batch reaches it. Edit captions generates them now, so they can be checked first.'
}

function Update-SelectedRowSummary {
    param([psobject]$Row)
    $number = Get-QueueRowNumber -Row $Row
    $SelectedTitleText.Text = "#$number  $(Get-QueueRowTitle -Row $Row)"
    $output = Get-QueueRowOutputPath -Row $Row
    $SelectedSavesAsText.Text = if ([bool]$Row.Done) { "Finished: $($Row.DoneOutput)" }
        elseif (-not [string]::IsNullOrWhiteSpace($output)) { "Saves as $output" }
        else { [string]$Row.Problem }
    $SelectedCaptionStatusText.Text = Get-QueueCaptionNote -Row $Row
}

function Update-BatchInspector {
    if ($script:IsLoading -or $script:AppMode -ne 'Batch') { return }
    if (-not [string]::IsNullOrWhiteSpace($script:BatchSettingsSection)) {
        $SettingsPanel.Visibility = [Windows.Visibility]::Visible
        $SettingsBackButton.Visibility = [Windows.Visibility]::Visible
        $BatchInspectorPanel.Visibility = [Windows.Visibility]::Collapsed
        return
    }
    $SettingsPanel.Visibility = [Windows.Visibility]::Collapsed
    $SettingsBackButton.Visibility = [Windows.Visibility]::Collapsed
    $BatchInspectorPanel.Visibility = [Windows.Visibility]::Visible
    if ($null -ne $script:BatchRun) {
        $NowRenderingView.Visibility = [Windows.Visibility]::Visible
        $SelectedVideoView.Visibility = [Windows.Visibility]::Collapsed
        $NoSelectionView.Visibility = [Windows.Visibility]::Collapsed
        return
    }
    $NowRenderingView.Visibility = [Windows.Visibility]::Collapsed
    $row = Get-SelectedQueueRow
    if ($null -eq $row) {
        $SelectedVideoView.Visibility = [Windows.Visibility]::Collapsed
        $NoSelectionView.Visibility = [Windows.Visibility]::Visible
        return
    }
    $NoSelectionView.Visibility = [Windows.Visibility]::Collapsed
    $SelectedVideoView.Visibility = [Windows.Visibility]::Visible
    $script:IsFillingInspector = $true
    try {
        # Only what differs is written back, so the caret of a box being typed
        # in does not jump.
        if ($SelectedNameText.Text -ne [string]$row.Name) { $SelectedNameText.Text = [string]$row.Name }
        if ($SelectedOutputFolderText.Text -ne [string]$row.OutputFolder) { $SelectedOutputFolderText.Text = [string]$row.OutputFolder }
        if ($SelectedImagesText.Text -ne [string]$row.ImageFolder) { $SelectedImagesText.Text = [string]$row.ImageFolder }
        if ($SelectedAudioText.Text -ne [string]$row.AudioPath) { $SelectedAudioText.Text = [string]$row.AudioPath }
        if ($SelectedWatermarkText.Text -ne [string]$row.WatermarkPath) { $SelectedWatermarkText.Text = [string]$row.WatermarkPath }
    }
    finally { $script:IsFillingInspector = $false }
    $SelectedThumbImage.Source = if ($null -ne $row.Visual) { $row.Visual.Thumb.Source } else { $null }
    $SelectedThumbHint.Visibility = ConvertTo-Visibility ($null -eq $SelectedThumbImage.Source)
    $SelectedThumbHint.Text = if ([bool]$row.ImagesOk) { 'First image of the folder' } else { 'The image folder is missing' }
    $isDone = [bool]$row.Done
    $SelectedPreviewButton.Visibility = ConvertTo-Visibility (-not $isDone)
    $SelectedCaptionsButton.Visibility = ConvertTo-Visibility (-not $isDone)
    $SelectedNameText.IsReadOnly = $isDone -or (Test-JobActive)
    Update-SelectedRowSummary -Row $row
}

function Open-OutputInFolder {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Start-Process explorer.exe -ArgumentList "/select,`"$Path`""
        return
    }
    $folder = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($folder) -and (Test-Path -LiteralPath $folder -PathType Container)) {
        Start-Process explorer.exe -ArgumentList "`"$folder`""
        return
    }
    Show-InfoMessage "That video is no longer where it was saved:`r`n$Path" 'Video not found'
}

# --- Moving between the queue and Single video -------------------------------

function Set-AppMode {
    param([ValidateSet('Batch', 'Single')][string]$Mode)
    if ($script:IsFullScreen) { Toggle-FullScreen }
    $script:AppMode = $Mode
    $isBatch = ($Mode -eq 'Batch')
    $ModeBatchButton.Background = if ($isBatch) { $script:RaisedBrush } else { $script:TransparentBrush }
    $ModeBatchButton.BorderBrush = if ($isBatch) { $script:StrongLineBrush } else { $script:TransparentBrush }
    $ModeBatchLabel.Foreground = if ($isBatch) { $script:TextBrush } else { $script:DimBrush }
    $ModeBatchLabel.FontWeight = if ($isBatch) { 'SemiBold' } else { 'Normal' }
    $ModeSingleButton.Background = if (-not $isBatch) { $script:RaisedBrush } else { $script:TransparentBrush }
    $ModeSingleButton.BorderBrush = if (-not $isBatch) { $script:StrongLineBrush } else { $script:TransparentBrush }
    $ModeSingleLabel.Foreground = if (-not $isBatch) { $script:TextBrush } else { $script:DimBrush }
    $ModeSingleLabel.FontWeight = if (-not $isBatch) { 'SemiBold' } else { 'Normal' }

    foreach ($control in @($BatchView, $BatchRailPanel, $BatchFooterButtons, $BatchCaptionNoteText, $BatchExportNoteText)) {
        $control.Visibility = ConvertTo-Visibility $isBatch
    }
    foreach ($control in @($SingleView, $SingleRailPanel, $SingleFooterButtons, $SingleOnlyCaptionPanel, $SingleOnlyExportPanel)) {
        $control.Visibility = ConvertTo-Visibility (-not $isBatch)
    }
    if ($isBatch) {
        Stop-PreviewPlayback
        Update-BatchNavHighlight
        Update-BatchInspector
    }
    else {
        $BatchInspectorPanel.Visibility = [Windows.Visibility]::Collapsed
        $SettingsPanel.Visibility = [Windows.Visibility]::Visible
        $SettingsBackButton.Visibility = [Windows.Visibility]::Collapsed
        Set-ActiveSection $script:SingleActiveSection
        Update-SingleView
    }
    Update-WorkflowState
    if (Test-JobActive) { return }
    if ($isBatch) { Update-BatchFooter }
}

function Update-SingleView {
    # Until there is a preview to play - or one being made - the stage shows
    # what is still needed rather than an empty black player.
    $hasPreview = ($null -ne $PreviewMedia.Source)
    $previewRendering = ($null -ne $script:RenderState) -and ([string]$script:RenderState.Kind -eq 'Preview')
    $showPlayer = $hasPreview -or $previewRendering
    $PlayerPanel.Visibility = ConvertTo-Visibility $showPlayer
    $SingleEmptyPanel.Visibility = ConvertTo-Visibility (-not $showPlayer)

    $row = Get-QueueRow -Id $script:QueuePreviewRowId
    $fromQueue = ($null -ne $row) -and
        [string]::Equals(([string]$row.ImageFolder).Trim(), $ImageFolderText.Text.Trim(), [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals(([string]$row.AudioPath).Trim(), $AudioText.Text.Trim(), [StringComparison]::OrdinalIgnoreCase)
    if (-not $fromQueue) { $script:QueuePreviewRowId = '' }
    $QueuePreviewBanner.Visibility = ConvertTo-Visibility $fromQueue
    if ($fromQueue) {
        $QueuePreviewBannerText.Text = "Previewing #$(Get-QueueRowNumber -Row $row)  $(Get-QueueRowTitle -Row $row)  from the batch queue. Motion, caption and backdrop changes made here apply to the whole batch."
    }
    Update-RecentSingleVideos
}

function Update-RecentSingleVideos {
    $RecentSinglePanel.Children.Clear()
    $entries = @($script:RenderHistory | Where-Object { [string]$_.Type -eq 'Final' } | Sort-Object StartedUtc -Descending | Select-Object -First 6)
    $RecentSingleEmptyText.Visibility = ConvertTo-Visibility ($entries.Count -eq 0)
    foreach ($entry in $entries) {
        $started = try { ([DateTime]::Parse([string]$entry.StartedUtc).ToLocalTime()).ToString('d MMM, HH:mm') } catch { '' }
        $title = [Windows.Controls.TextBlock]::new()
        $title.Text = [string]$entry.Name
        $title.FontSize = 12.5
        $title.TextTrimming = 'CharacterEllipsis'
        $detail = [Windows.Controls.TextBlock]::new()
        $detail.Text = "$($entry.Status)   $started"
        $detail.FontSize = 11
        $detail.Foreground = $script:MutedBrush
        $detail.Margin = [Windows.Thickness]::new(0, 2, 0, 0)
        $stack = [Windows.Controls.StackPanel]::new()
        [void]$stack.Children.Add($title)
        [void]$stack.Children.Add($detail)
        $button = [Windows.Controls.Button]::new()
        $button.Style = $window.FindResource('ToolButtonStyle')
        $button.Margin = [Windows.Thickness]::new(-8, 1, 0, 1)
        $button.Content = $stack
        $button.Tag = [string]$entry.OutputPath
        $button.ToolTip = [string]$entry.OutputPath
        $button.Add_Click({ param($sender, $eventArgs) Open-OutputInFolder -Path ([string]$sender.Tag) })
        [void]$RecentSinglePanel.Children.Add($button)
    }
}

function Start-QueueRowPreview {
    # Opens a queued video in Single video, with the player, the storyboard and
    # the caption handles, and renders its first minute. The timeline made for
    # that preview is kept with the video, so the batch renders what was seen.
    param([string]$Id)
    if (Test-JobActive) { return }
    $row = Get-QueueRow -Id $Id
    if ($null -eq $row) { return }
    Select-QueueRow -Id $Id
    $ImageFolderText.Text = [string]$row.ImageFolder
    $AudioText.Text = [string]$row.AudioPath
    $WatermarkText.Text = [string]$row.WatermarkPath
    $OutputText.Text = Get-QueueRowOutputPath -Row $row
    $script:QueuePreviewRowId = [string]$row.Id
    Set-AppMode 'Single'
    Start-VideoRender 'Preview'
    Update-SingleView
}

function Edit-QueueRowCaptions {
    param([string]$Id)
    if (Test-JobActive) { return }
    $row = Get-QueueRow -Id $Id
    if ($null -eq $row) { return }
    if (-not (Test-VoiceoverFile ([string]$row.AudioPath))) {
        Show-ErrorMessage 'Choose this video''s voiceover first.' 'Edit captions'
        return
    }
    $cachePath = Get-CaptionCachePath -AudioPath ([string]$row.AudioPath) -DataRoot $script:DataRoot
    if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
        Show-CaptionEditor -AudioPath ([string]$row.AudioPath)
        return
    }
    $choice = [Windows.MessageBox]::Show($window,
        "Captions for this voiceover have not been generated yet. Generate them now and open them to edit?`r`n`r`nThis runs on this computer and takes a few minutes.",
        'Edit captions', [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Question)
    if ($choice -ne [Windows.MessageBoxResult]::Yes) { return }
    $script:PendingCaptionEditorAudio = [string]$row.AudioPath
    [void](Start-CaptionGeneration -Force $true -AudioPath ([string]$row.AudioPath))
}

# --- Keeping the queue between sessions ---------------------------------------

function Save-QueueState {
    try {
        $items = @(foreach ($row in $script:QueueRows) {
            [ordered]@{
                Channel = [string]$row.Channel; Label = [string]$row.Label
                ImageFolder = [string]$row.ImageFolder; AudioPath = [string]$row.AudioPath
                WatermarkPath = [string]$row.WatermarkPath; OutputFolder = [string]$row.OutputFolder
                Name = [string]$row.Name; ImageCount = [int]$row.ImageCount; Duration = [double]$row.Duration
                Done = [bool]$row.Done; DoneOutput = [string]$row.DoneOutput
            }
        })
        $json = if ($items.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject $items -Depth 4 }
        [IO.File]::WriteAllText($script:QueueStatePath, $json, [Text.UTF8Encoding]::new($false))
    }
    catch { Write-ToolDiagnostic 'The batch queue could not be saved.' $_.Exception }
}

function Import-QueueState {
    if (-not (Test-Path -LiteralPath $script:QueueStatePath -PathType Leaf)) { return }
    try {
        # Assigned directly, not wrapped in @(): Windows PowerShell 5.1 would
        # otherwise keep the JSON array as one nested Object[].
        $loaded = [IO.File]::ReadAllText($script:QueueStatePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($entry in $loaded) {
            if ($null -eq $entry -or $null -eq $entry.PSObject.Properties['ImageFolder']) { continue }
            $row = New-QueueRow -Channel ([string]$entry.Channel) -Label ([string]$entry.Label) -ImageFolder ([string]$entry.ImageFolder) `
                -AudioPath ([string]$entry.AudioPath) -WatermarkPath ([string]$entry.WatermarkPath) -OutputFolder ([string]$entry.OutputFolder) `
                -Name ([string]$entry.Name) -ImageCount ([int]$entry.ImageCount)
            if ($null -ne $entry.PSObject.Properties['Duration']) { $row.Duration = [double]$entry.Duration }
            if ($null -ne $entry.PSObject.Properties['Done']) { $row.Done = [bool]$entry.Done }
            if ($null -ne $entry.PSObject.Properties['DoneOutput']) { $row.DoneOutput = [string]$entry.DoneOutput }
            Add-QueueRow -Row $row -Deferred
        }
        Complete-QueueChange -Save $false
    }
    catch { Write-ToolDiagnostic 'The saved batch queue could not be loaded.' $_.Exception }
}

# --- Rendering the queue ------------------------------------------------------

function Start-QueueRender {
    # Turns every unfinished video into a saved project and hands them to the
    # batch worker, the same path Render saved projects takes.
    if (Test-JobActive) { return }
    $pending = @($script:QueueRows | Where-Object { -not [bool]$_.Done })
    if ($pending.Count -eq 0) {
        $message = if ($script:QueueRows.Count -gt 0) { 'Every video in the queue is already finished. Clear finished, then scan or add the next videos.' } else { 'Scan your channels folder or add a video first.' }
        Show-InfoMessage $message 'Nothing to render'
        return
    }
    foreach ($row in $pending) { Update-QueueRowFiles -Row $row }
    Update-QueueStatuses
    $blocked = @($pending | Where-Object { $_.ProblemKind -ne 'ok' })
    if ($blocked.Count -gt 0) {
        $first = $blocked[0]
        Set-ChannelFilter -Key '*'
        Select-QueueRow -Id ([string]$first.Id)
        $first.Visual.Border.BringIntoView()
        $count = if ($blocked.Count -eq 1) { 'One video is' } else { "$($blocked.Count) videos are" }
        Show-ErrorMessage "$count not ready to render yet. The first is #$(Get-QueueRowNumber -Row $first), $(Get-QueueRowTitle -Row $first):`r`n`r`n$($first.Problem)" 'Not ready to render'
        Update-BatchFooter
        return
    }
    try {
        Assert-FFmpegAvailable
        $settings = Get-UiSettings
        # Reading a watermark costs an FFprobe launch, and a batch of fifty
        # videos sharing one watermark would otherwise pay for it fifty times.
        $checkedWatermarks = @{}
        $queueDirectory = Join-Path (Join-Path $script:DataRoot 'queue-projects') ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $queueDirectory -Force | Out-Null
        $projectPaths = [Collections.Generic.List[string]]::new()
        for ($index = 0; $index -lt $pending.Count; $index++) {
            $row = $pending[$index]
            $label = "#$(Get-QueueRowNumber -Row $row) $(Get-QueueRowTitle -Row $row)"
            $StatusText.Text = "Checking video $($index + 1) of $($pending.Count): $(Get-QueueRowTitle -Row $row)"
            $window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
            $imageFolder = ([string]$row.ImageFolder).Trim()
            $audio = ([string]$row.AudioPath).Trim()
            $watermark = ([string]$row.WatermarkPath).Trim()
            $output = Get-QueueRowOutputPath -Row $row
            $outputFolder = [string]$row.OutputFolder
            $resolvedFolder = Split-Path -Parent $output
            # The row's own folder is created if it is missing; any other
            # folder typed in front of the name has to exist already.
            if (-not [string]::IsNullOrWhiteSpace($outputFolder) -and
                [string]::Equals($resolvedFolder.TrimEnd('\'), $outputFolder.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -and
                -not (Test-Path -LiteralPath $resolvedFolder -PathType Container)) {
                New-Item -ItemType Directory -Path $resolvedFolder -Force | Out-Null
            }
            if (-not $checkedWatermarks.ContainsKey($watermark)) {
                if (-not (Test-VideoStream $watermark)) { throw "$($label): FFprobe could not read the selected watermark video." }
                $checkedWatermarks[$watermark] = $true
            }
            if ([string]::IsNullOrWhiteSpace($resolvedFolder) -or -not (Test-Path -LiteralPath $resolvedFolder -PathType Container)) { throw "$($label): the output folder does not exist." }
            $images = @(Get-ValidatedImages $imageFolder)
            $duration = Get-MediaDurationSeconds -FfprobePath $script:FfprobePath -MediaPath $audio
            $row.Duration = $duration
            $signature = Get-PlanSignature -Images $images -Duration $duration -Settings $settings -AudioPath $audio
            $timeline = $null
            if ($null -ne $row.PreviewPlan -and [string]$row.PreviewPlanSignature -eq $signature) { $timeline = $row.PreviewPlan }
            else {
                $timeline = New-TimelinePlan -ImagePaths $images -AudioDurationSeconds $duration -MinimumDurationSeconds $settings.MinimumDuration -MaximumDurationSeconds $settings.MaximumDuration -Fps $script:DeliveryFps
            }
            $project = [ordered]@{ SchemaVersion = 1; ImageFolder = $imageFolder; AudioPath = $audio; WatermarkPath = $watermark; OutputPath = $output; Settings = $settings; PlanSignature = $signature; Timeline = $timeline }
            $projectPath = Join-Path $queueDirectory ('video-{0:D3}.svp.json' -f ($index + 1))
            [IO.File]::WriteAllText($projectPath, ($project | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
            $projectPaths.Add($projectPath)
        }
        Save-QueueState
        Start-BatchRender -ProjectPaths $projectPaths.ToArray()
    }
    catch {
        Write-ToolDiagnostic 'Bulk queue preparation failed.' $_.Exception
        Show-ErrorMessage $_.Exception.Message 'Could not build render queue'
        Update-BatchFooter
    }
}

function New-RenderRowVisual {
    # One line of the batch while it renders: its status, or its progress.
    param([psobject]$Item)
    $border = [Windows.Controls.Border]::new()
    $border.BorderBrush = $script:RowLineBrush
    $border.BorderThickness = [Windows.Thickness]::new(0, 0, 0, 1)
    $border.Padding = [Windows.Thickness]::new(12, 0, 12, 0)
    $border.Height = 50
    $grid = [Windows.Controls.Grid]::new()
    New-QueueColumns -Grid $grid -Widths @(30, -1, 140, 68, 210, 82)
    $border.Child = $grid
    $number = New-QueueCellText -Column 0 -Foreground $script:MutedBrush -FontSize 12
    $number.Text = [string]($Item.Index + 1)
    [void]$grid.Children.Add($number)
    $title = New-QueueCellText -Column 1 -Foreground $script:TextBrush -FontSize 13
    $title.Text = [string]$Item.Title
    $title.ToolTip = [string]$Item.DestinationPath
    $title.Margin = [Windows.Thickness]::new(0, 0, 10, 0)
    [void]$grid.Children.Add($title)
    $channel = New-QueueCellText -Column 2 -Foreground $script:DimBrush -FontSize 12
    $channel.Text = if ([string]::IsNullOrWhiteSpace([string]$Item.Channel)) { '-' } else { [string]$Item.Channel }
    $channel.Margin = [Windows.Thickness]::new(10, 0, 8, 0)
    [void]$grid.Children.Add($channel)
    $length = New-QueueCellText -Column 3 -Foreground $script:DimBrush -FontSize 12
    $length.Text = if ([double]$Item.Duration -gt 0) { Format-Clock ([double]$Item.Duration) } else { '-' }
    [void]$grid.Children.Add($length)

    $statusHost = [Windows.Controls.Grid]::new()
    $statusHost.VerticalAlignment = 'Center'
    $statusHost.Margin = [Windows.Thickness]::new(0, 0, 14, 0)
    [Windows.Controls.Grid]::SetColumn($statusHost, 4)
    $pill = New-StatusPill
    [void]$statusHost.Children.Add($pill.Border)
    $progressHost = [Windows.Controls.StackPanel]::new()
    $progressText = [Windows.Controls.TextBlock]::new()
    $progressText.FontSize = 11.5
    $progressText.Foreground = $script:AccentBrush
    $progressBar = [Windows.Controls.ProgressBar]::new()
    $progressBar.Minimum = 0
    $progressBar.Maximum = 100
    $progressBar.Height = 5
    $progressBar.Margin = [Windows.Thickness]::new(0, 5, 0, 0)
    [void]$progressHost.Children.Add($progressText)
    [void]$progressHost.Children.Add($progressBar)
    [void]$statusHost.Children.Add($progressHost)
    [void]$grid.Children.Add($statusHost)

    $open = [Windows.Controls.Button]::new()
    $open.Style = $window.FindResource('QuietButtonStyle')
    $open.Content = 'Open'
    $open.Padding = [Windows.Thickness]::new(12, 4, 12, 4)
    $open.HorizontalAlignment = 'Right'
    $open.Tag = [string]$Item.DestinationPath
    $open.ToolTip = 'Show the finished video in its folder'
    $open.Add_Click({ param($sender, $eventArgs) Open-OutputInFolder -Path ([string]$sender.Tag) })
    [Windows.Controls.Grid]::SetColumn($open, 5)
    [void]$grid.Children.Add($open)

    return [pscustomobject]@{ Border = $border; Pill = $pill; ProgressHost = $progressHost; ProgressText = $progressText; ProgressBar = $progressBar; OpenButton = $open }
}

function Update-RenderRowVisual {
    param([psobject]$Item)
    $visual = $Item.Visual
    if ($null -eq $visual) { return }
    $isRendering = ($Item.State -eq 'Rendering')
    $visual.ProgressHost.Visibility = ConvertTo-Visibility $isRendering
    $visual.Pill.Border.Visibility = ConvertTo-Visibility (-not $isRendering)
    $visual.OpenButton.Visibility = ConvertTo-Visibility ($Item.State -eq 'Done')
    $visual.Border.Background = if ($isRendering) { $script:RenderingRowBrush } else { $script:TransparentBrush }
    switch ([string]$Item.State) {
        'Rendering' {
            $visual.ProgressBar.Value = [double]$Item.Percent
            $visual.ProgressText.Text = if ([string]$Item.Stage -eq 'captions') { "Captions $([int][Math]::Floor([double]$Item.Percent))%" } else { "Rendering $([int][Math]::Floor([double]$Item.Percent))%" }
        }
        'Done' { Set-StatusPill -Pill $visual.Pill -Kind 'done' -Text 'Done' }
        'Paused' { Set-StatusPill -Pill $visual.Pill -Kind 'warn' -Text 'Paused' }
        'Failed' { Set-StatusPill -Pill $visual.Pill -Kind 'bad' -Text 'Failed' }
        default { Set-StatusPill -Pill $visual.Pill -Kind 'queued' -Text 'Queued' }
    }
}

function Show-BatchRun {
    # The batch takes the queue's place until it is finished and looked at.
    param([psobject]$Run)
    $script:BatchRun = $Run
    $RenderRowsPanel.Children.Clear()
    foreach ($item in @($Run.Items)) {
        $item.Visual = New-RenderRowVisual -Item $item
        Update-RenderRowVisual -Item $item
        [void]$RenderRowsPanel.Children.Add($item.Visual.Border)
    }
    $NowRenderingImage.Source = $null
    $NowRenderingImageHint.Visibility = [Windows.Visibility]::Visible
    $script:BatchSettingsSection = ''
    if ($script:AppMode -ne 'Batch') { Set-AppMode 'Batch' }
    Update-BatchNavHighlight
    Update-QueueEditing
    Update-BatchHeader
    Update-BatchInspector
    Update-BatchFooter
}

function Close-BatchRun {
    # Back to the queue once the batch has been looked at.
    $run = $script:BatchRun
    if ($null -eq $run -or [bool]$run.Running) { return }
    $script:BatchRun = $null
    $RenderRowsPanel.Children.Clear()
    Complete-QueueChange -Save $false
    Update-BatchInspector
}

function Set-BatchItemDone {
    param([psobject]$Item)
    if ($Item.State -eq 'Done') { return }
    $Item.State = 'Done'
    $Item.Percent = 100.0
    $script:FinalOutputPath = [string]$Item.DestinationPath
    $row = Get-QueueRow -Id ([string]$Item.RowId)
    if ($null -ne $row) {
        $row.Done = $true
        $row.DoneOutput = [string]$Item.DestinationPath
    }
}

function Update-BatchRunProgress {
    # The worker reports which video it is on and how far into it. Everything
    # before that video is finished; everything after it is still waiting.
    param([int]$ItemIndex, [double]$ItemPercent, [string]$Stage)
    $run = $script:BatchRun
    if ($null -eq $run -or $ItemIndex -lt 0) { return }
    $items = @($run.Items)
    $changed = $false
    for ($index = 0; $index -lt $items.Count; $index++) {
        $item = $items[$index]
        $before = "$($item.State)|$($item.Percent)|$($item.Stage)"
        if ($index -lt $ItemIndex -or ($index -eq $ItemIndex -and $Stage -eq 'done')) { Set-BatchItemDone -Item $item }
        elseif ($index -eq $ItemIndex) {
            $item.State = 'Rendering'
            $item.Percent = [Math]::Max(0.0, [Math]::Min(100.0, $ItemPercent))
            $item.Stage = $Stage
        }
        elseif ($item.State -ne 'Queued') { $item.State = 'Queued' }
        if ($before -ne "$($item.State)|$($item.Percent)|$($item.Stage)") {
            Update-RenderRowVisual -Item $item
            $changed = $true
        }
    }
    if ($changed) { Update-BatchHeader }
}

function Read-BatchProgress {
    param([string]$Path)
    $result = [pscustomobject]@{ Percent = 0.0; Message = 'Starting the batch...'; Item = -1; ItemPercent = 0.0; Stage = '' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }
    try {
        $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $culture = [Globalization.CultureInfo]::InvariantCulture
        $match = [regex]::Match($text, '(?m)^percent=([0-9.]+)')
        if ($match.Success) { $result.Percent = [double]::Parse($match.Groups[1].Value, $culture) }
        $match = [regex]::Match($text, '(?m)^message=(.*)$')
        if ($match.Success) { $result.Message = $match.Groups[1].Value.Trim() }
        $match = [regex]::Match($text, '(?m)^item=(\d+)')
        if ($match.Success) { $result.Item = [int]$match.Groups[1].Value }
        $match = [regex]::Match($text, '(?m)^itempercent=([0-9.]+)')
        if ($match.Success) { $result.ItemPercent = [double]::Parse($match.Groups[1].Value, $culture) }
        $match = [regex]::Match($text, '(?m)^stage=(.*)$')
        if ($match.Success) { $result.Stage = $match.Groups[1].Value.Trim() }
    }
    catch {}
    return $result
}

function Get-BatchSecondsDone {
    # Seconds of video finished so far: whole videos before the current one,
    # and the rendered part of the current one. Captions take time but make
    # no video, so they count for nothing here.
    $state = $script:RenderState
    if ($null -eq $state -or -not $state.PSObject.Properties['ItemDurations']) { return 0.0 }
    $durations = @($state.ItemDurations)
    $current = [int]$state.CurrentItem
    $done = 0.0
    for ($index = 0; $index -lt $durations.Count -and $index -lt $current; $index++) { $done += [double]$durations[$index] }
    if ($current -ge 0 -and $current -lt $durations.Count) {
        if ([string]$state.Stage -eq 'done') { $done += [double]$durations[$current] }
        elseif ([string]$state.Stage -eq 'rendering') { $done += [double]$durations[$current] * ([double]$state.ItemPercent / 100.0) }
    }
    return $done
}

function Format-ElapsedTime {
    param([double]$Seconds)
    if ($Seconds -lt 60) { return 'under 1 min' }
    $totalMinutes = [int][Math]::Floor($Seconds / 60.0)
    $hours = [int][Math]::Floor($totalMinutes / 60)
    if ($hours -gt 0) { return ('{0} h {1:00} min' -f $hours, ($totalMinutes - ($hours * 60))) }
    return "$totalMinutes min"
}

function Update-NowRenderingPanel {
    $state = $script:RenderState
    $run = $script:BatchRun
    if ($null -eq $run) { return }
    $items = @($run.Items)
    if ($null -eq $state -or [string]$state.Kind -ne 'Batch') {
        $NowRenderingLabel.Text = 'BATCH'
        $NowRenderingTitleText.Text = [string]$run.ResultText
        $NowSpeedText.Text = if ([double]$run.MeasuredSpeed -gt 0) { '{0:0.0}x' -f [double]$run.MeasuredSpeed } else { '-' }
        $NowVideoPercentText.Text = '-'
        $NowRenderingStageText.Text = ''
        return
    }
    $current = [int]$state.CurrentItem
    $NowRenderingLabel.Text = if ($current -ge 0 -and $items.Count -gt 0) { "NOW RENDERING  -  VIDEO $([Math]::Min($current + 1, $items.Count)) OF $($items.Count)" } else { 'NOW RENDERING' }
    if ($current -ge 0 -and $current -lt $items.Count) { $NowRenderingTitleText.Text = [string]$items[$current].Title }
    $elapsed = ([DateTime]::UtcNow - [DateTime]$state.StartedUtc).TotalSeconds
    $NowElapsedText.Text = Format-ElapsedTime $elapsed
    $NowEncoderText.Text = [string]$state.Encoder
    $NowEncoderText.ToolTip = [string]$state.Encoder
    $done = Get-BatchSecondsDone
    $NowSpeedText.Text = if ($done -gt 1 -and $elapsed -ge 20) { '{0:0.0}x' -f ($done / $elapsed) } else { 'measuring' }
    $NowVideoPercentText.Text = switch ([string]$state.Stage) {
        'captions' { "Captions $([int][Math]::Floor([double]$state.ItemPercent))%" }
        'rendering' { "$([int][Math]::Floor([double]$state.ItemPercent))%" }
        'done' { '100%' }
        default { 'starting' }
    }
    $NowRenderingStageText.Text = [string]$state.Message
    Update-NowRenderingThumbnail
}

function Update-NowRenderingThumbnail {
    # A frame from the end of the newest finished stretch of the video being
    # rendered, taken by FFmpeg in the background every few seconds when a new
    # stretch is done. Unfinished stretches are left alone: an MP4 is not
    # readable until FFmpeg has closed it.
    $state = $script:RenderState
    $run = $script:BatchRun
    if ($null -eq $state -or $null -eq $run -or [string]$state.Kind -ne 'Batch') { return }
    $items = @($run.Items)
    $current = [int]$state.CurrentItem
    if ($current -lt 0 -or $current -ge $items.Count) { return }
    $thumb = $script:NowRenderingThumb
    if ($null -ne $thumb -and [int]$thumb.ItemIndex -ne $current) {
        # A new video: its first frame comes once its first stretch is done.
        $NowRenderingImage.Source = $null
        $NowRenderingImageHint.Visibility = [Windows.Visibility]::Visible
    }
    if ($null -ne $thumb -and $null -ne $thumb.Process) {
        if (-not $thumb.Process.HasExited) { return }
        $thumb.Process = $null
        if ([int]$thumb.ItemIndex -eq $current -and (Test-Path -LiteralPath ([string]$thumb.OutputPath) -PathType Leaf)) {
            try {
                $bitmap = [Windows.Media.Imaging.BitmapImage]::new()
                $bitmap.BeginInit()
                $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                $bitmap.UriSource = [uri]([string]$thumb.OutputPath)
                $bitmap.EndInit()
                $bitmap.Freeze()
                $NowRenderingImage.Source = $bitmap
                $NowRenderingImageHint.Visibility = [Windows.Visibility]::Collapsed
            }
            catch {}
        }
        Remove-Item -LiteralPath ([string]$thumb.OutputPath) -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $thumb -and [int]$thumb.ItemIndex -eq $current -and ([DateTime]::UtcNow - [DateTime]$thumb.CheckedUtc).TotalSeconds -lt 4) { return }
    $directory = [string]$items[$current].ResumeDirectory
    $segment = ''
    if (-not [string]::IsNullOrWhiteSpace($directory) -and (Test-Path -LiteralPath $directory -PathType Container)) {
        $progressFiles = @(Get-ChildItem -LiteralPath $directory -Filter 'progress-*.txt' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
        foreach ($file in $progressFiles) {
            $text = ''
            try { $text = [IO.File]::ReadAllText($file.FullName) } catch { continue }
            if ($text -notmatch 'progress=end') { continue }
            $candidate = Join-Path $directory (($file.BaseName -replace '^progress-', 'segment-') + '.mp4')
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $segment = $candidate; break }
        }
    }
    $previousSegment = if ($null -ne $thumb -and [int]$thumb.ItemIndex -eq $current) { [string]$thumb.Segment } else { '' }
    $script:NowRenderingThumb = [pscustomobject]@{ ItemIndex = $current; CheckedUtc = [DateTime]::UtcNow; Segment = $previousSegment; Process = $null; OutputPath = '' }
    if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq $previousSegment -or [string]::IsNullOrWhiteSpace([string]$script:FfmpegPath)) { return }
    $outputPath = Join-Path $script:DataRoot ('now-rendering-{0}.jpg' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        $arguments = Join-ProcessArguments @('-y', '-hide_banner', '-loglevel', 'error', '-sseof', '-1', '-i', $segment, '-frames:v', '1', '-vf', 'scale=480:-2', $outputPath)
        $process = Start-Process -FilePath $script:FfmpegPath -ArgumentList $arguments -PassThru -WindowStyle Hidden
        $script:NowRenderingThumb.Process = $process
        $script:NowRenderingThumb.OutputPath = $outputPath
        $script:NowRenderingThumb.Segment = $segment
    }
    catch { Write-ToolDiagnostic 'The rendering thumbnail could not be taken.' $_.Exception }
}

function Start-BatchRender {
    param([string[]]$ProjectPaths = @(), [string]$HistoryId = '')
    if ($null -ne $script:RenderProcess -and -not $script:RenderProcess.HasExited) { return }
    $projectPaths = @($ProjectPaths)
    if ($projectPaths.Count -eq 0) {
        $projectPaths = @(Select-OpenFiles -Title 'Select saved slideshow projects to render' -Filter 'Slideshow projects (*.svp.json)|*.svp.json|JSON files (*.json)|*.json')
    }
    if ($projectPaths.Count -eq 0) { return }
    $batchDirectory = ''
    try {
        Assert-FFmpegAvailable
        $encoder = Select-AvailableEncoder
        $batchId = [guid]::NewGuid().ToString('N')
        $batchDirectory = Join-Path $script:DataRoot "batch-$batchId"
        New-Item -ItemType Directory -Path $batchDirectory -Force | Out-Null
        $prepared = [Collections.Generic.List[object]]::new()
        $displayItems = [Collections.Generic.List[object]]::new()
        $existingOutputs = [Collections.Generic.List[string]]::new()

        for ($index = 0; $index -lt $projectPaths.Count; $index++) {
            $StatusText.Text = "Preparing batch project $($index + 1) of $($projectPaths.Count)..."
            $window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
            $projectPath = $projectPaths[$index]
            $project = [IO.File]::ReadAllText($projectPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ([int]$project.SchemaVersion -ne 1 -or $null -eq $project.Timeline -or @($project.Timeline.Items).Count -eq 0) {
                throw "Project must be previewed and saved before batch rendering:`r`n$projectPath"
            }
            foreach ($requiredPath in @([string]$project.AudioPath, [string]$project.WatermarkPath)) {
                if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw "A batch project has missing media:`r`n$requiredPath" }
            }
            foreach ($timelineItem in $project.Timeline.Items) {
                if (-not (Test-Path -LiteralPath ([string]$timelineItem.ImagePath) -PathType Leaf)) { throw "A batch project has a missing image:`r`n$($timelineItem.ImagePath)" }
            }
            $destination = [string]$project.OutputPath
            if ([string]::IsNullOrWhiteSpace($destination) -or [IO.Path]::GetExtension($destination).ToLowerInvariant() -ne '.mp4' -or -not (Test-Path -LiteralPath (Split-Path -Parent $destination) -PathType Container)) {
                throw "A batch project has an invalid MP4 output path:`r`n$projectPath"
            }
            if (Test-Path -LiteralPath $destination -PathType Leaf) { $existingOutputs.Add($destination) }

            $captionMode = 'Off'
            if ($project.Settings.PSObject.Properties['CaptionMode']) { $captionMode = [string]$project.Settings.CaptionMode }
            # Carry the project's own settings through whole. This used to copy
            # seven fields by hand, which silently dropped everything else the
            # project had saved - all the caption styling, the volume, and any
            # setting added later. A hand-written list cannot help going stale:
            # it is only correct until the next setting exists, and then it is
            # wrong quietly, in batch renders only.
            $settings = $project.Settings
            $settingDefaults = @{
                MinimumDuration = 5.0; MaximumDuration = 7.0; ZoomMaximum = 110.0
                BlurAmount = 40.0; BackgroundBrightness = 65.0; Quality = 'YouTube'
            }
            foreach ($key in $settingDefaults.Keys) {
                if ($null -eq $settings.PSObject.Properties[$key]) {
                    $settings | Add-Member -NotePropertyName $key -NotePropertyValue $settingDefaults[$key]
                }
            }
            if ($null -eq $settings.PSObject.Properties['CaptionMode']) {
                $settings | Add-Member -NotePropertyName CaptionMode -NotePropertyValue $captionMode
            }
            else { $settings.CaptionMode = $captionMode }
            $filterBackend = Select-AvailableFilterBackend -Timeline $project.Timeline -Settings $settings -WatermarkPath ([string]$project.WatermarkPath)
            $projectRun = Join-Path $batchDirectory ('project-{0:D3}' -f $index)
            New-Item -ItemType Directory -Path $projectRun -Force | Out-Null
            $captionPath = if ($captionMode -ne 'Off') { Get-CaptionCachePath -AudioPath ([string]$project.AudioPath) -DataRoot $script:DataRoot } else { '' }
            $captionJobPath = ''
            if ($captionMode -ne 'Off' -and -not (Test-Path -LiteralPath $captionPath -PathType Leaf)) {
                $captionJobPath = Join-Path $projectRun 'caption-job.json'
                $captionJob = [ordered]@{
                    FfmpegPath = $script:FfmpegPath
                    AudioPath = [string]$project.AudioPath
                    EngineRoot = Get-CaptionEngineRoot
                    OutputSrt = $captionPath
                    ProgressPath = Join-Path $projectRun 'caption-progress.txt'
                    ErrorPath = Join-Path $projectRun 'caption-error.log'
                }
                [IO.File]::WriteAllText($captionJobPath, ($captionJob | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
            }
            $renderJobPath = Join-Path $projectRun 'render-job.json'
            $renderProgressPath = Join-Path $projectRun 'render-progress.txt'
            $filterDeviceKey = if ($null -eq $script:FilterVulkanDeviceIndex) { -1 } else { [int]$script:FilterVulkanDeviceIndex }
            $projectFingerprint = Get-StableHash (([IO.File]::ReadAllText($projectPath, [Text.Encoding]::UTF8)) + "||$encoder||$filterBackend||$filterDeviceKey||$($script:RenderPipelineVersion)")
            $resumeDirectory = Join-Path (Join-Path $script:DataRoot 'resume') $projectFingerprint
            $stagingPath = Join-Path (Split-Path -Parent $destination) ".$([IO.Path]::GetFileNameWithoutExtension($destination)).batch-$batchId-$index.mp4"
            $renderJob = [ordered]@{
                FfmpegPath = $script:FfmpegPath
                FfprobePath = $script:FfprobePath
                EngineModulePath = Join-Path $script:AppRoot 'SlideshowEngine.psm1'
                PipelineVersion = $script:RenderPipelineVersion
                Timeline = $project.Timeline
                AudioPath = [string]$project.AudioPath
                WatermarkPath = [string]$project.WatermarkPath
                DestinationPath = $destination
                StagingPath = $stagingPath
                PreviewPath = ''
                ReusePreview = $false
                CaptionPath = $captionPath
                CaptionMode = $captionMode
                Settings = $settings
                Encoder = $encoder
                VulkanDeviceIndex = if ($null -eq $script:VulkanDeviceIndex) { 0 } else { [int]$script:VulkanDeviceIndex }
                FilterBackend = $filterBackend
                FilterVulkanDeviceIndex = if ($null -eq $script:FilterVulkanDeviceIndex) { -1 } else { [int]$script:FilterVulkanDeviceIndex }
                OpenClDevice = if ($null -eq $script:OpenClDevice) { '' } else { [string]$script:OpenClDevice }
                ScreenKernelPath = $script:ScreenKernelPath
                ParallelSegments = Get-RecommendedParallelSegments -Encoder $encoder
                SegmentSeconds = 30
                LoudnessTargetLufs = -14.0
                ResumeDirectory = $resumeDirectory
                ProgressPath = $renderProgressPath
                ErrorPath = Join-Path $projectRun 'render-error.log'
                ChildPidPath = Join-Path $projectRun 'ffmpeg-child.pid'
            }
            [IO.File]::WriteAllText($renderJobPath, ($renderJob | ConvertTo-Json -Depth 15), [Text.UTF8Encoding]::new($false))
            $prepared.Add([pscustomobject]@{ RenderJobPath = $renderJobPath; CaptionJobPath = $captionJobPath; DestinationPath = $destination })
            # What the window shows for this video while the batch runs. Its
            # resume folder is where its finished stretches appear, which is
            # what the rendering thumbnail is taken from.
            $displayItems.Add([pscustomobject]@{
                Index = $index
                Title = [IO.Path]::GetFileNameWithoutExtension($destination)
                Channel = ''
                Duration = [double]$project.Timeline.AudioDurationSeconds
                DestinationPath = $destination
                ResumeDirectory = $resumeDirectory
                RowId = ''
                State = 'Queued'
                Percent = 0.0
                Stage = ''
                Visual = $null
            })
        }
        # A video that came from the queue is matched back to its line there by
        # the file it writes, which also covers a batch resumed from history.
        foreach ($displayItem in $displayItems) {
            foreach ($queueRow in $script:QueueRows) {
                if ([bool]$queueRow.Done) { continue }
                if ([string]::Equals((Get-QueueRowOutputPath -Row $queueRow), [string]$displayItem.DestinationPath, [StringComparison]::OrdinalIgnoreCase)) {
                    $displayItem.RowId = [string]$queueRow.Id
                    $displayItem.Channel = [string]$queueRow.Channel
                    $displayItem.Title = Get-QueueRowTitle -Row $queueRow
                    break
                }
            }
        }

        if ($existingOutputs.Count -gt 0) {
            $choice = [Windows.MessageBox]::Show($window, "$($existingOutputs.Count) batch output file(s) already exist. Replace each only after its new render succeeds?", 'Confirm batch replacement', [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Warning)
            if ($choice -ne [Windows.MessageBoxResult]::Yes) {
                Remove-CaptionRunDirectory $batchDirectory
                $StatusText.Text = 'Batch not started.'
                Update-BatchFooter
                return
            }
        }

        $batchProgressPath = Join-Path $batchDirectory 'batch-progress.txt'
        $batchErrorPath = Join-Path $batchDirectory 'batch-error.log'
        $batchJobPath = Join-Path $batchDirectory 'batch-job.json'
        $batchJob = [ordered]@{
            Items = $prepared.ToArray()
            CaptionWorkerPath = Join-Path $script:AppRoot 'CaptionWorker.ps1'
            RenderWorkerPath = Join-Path $script:AppRoot 'SlideshowRenderWorker.ps1'
            ProgressPath = $batchProgressPath
            ErrorPath = $batchErrorPath
            ChildPidPath = Join-Path $batchDirectory 'child.pid'
        }
        [IO.File]::WriteAllText($batchJobPath, ($batchJob | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        if ([string]::IsNullOrWhiteSpace($HistoryId)) {
            $historyEntry = Add-RenderHistoryEntry -Type Batch -Name "Batch - $($prepared.Count) projects" -OutputPath ([string]$prepared[$prepared.Count - 1].DestinationPath) -Encoder $encoder -ProjectPaths $projectPaths
            $HistoryId = $historyEntry.Id
        }
        else {
            $existingHistory = @($script:RenderHistory | Where-Object { [string]$_.Id -eq $HistoryId } | Select-Object -First 1)
            if ($existingHistory.Count -gt 0) {
                $existingHistory[0].Status = 'Rendering'
                $existingHistory[0].Progress = 0
                $existingHistory[0].Detail = 'Batch rendering restarted.'
                $existingHistory[0].UpdatedUtc = [DateTime]::UtcNow.ToString('o')
                Save-RenderHistory
            }
        }
        $argumentLine = Join-ProcessArguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $script:AppRoot 'SlideshowBatchWorker.ps1'),'-JobPath',$batchJobPath)
        $script:CancelRequested = $false
        $script:RenderState = [pscustomobject]@{
            Kind = 'Batch'
            IsBatch = $true
            IsWorker = $true
            RunDirectory = $batchDirectory
            ProgressPath = $batchProgressPath
            ErrorPath = $batchErrorPath
            ChildPidPath = $batchJob.ChildPidPath
            StagingPath = ''
            DestinationPath = [string]$prepared[$prepared.Count - 1].DestinationPath
            OutputPaths = @($prepared | ForEach-Object { $_.DestinationPath })
            # Seconds of video in each project, so progress, speed and the
            # finish time are weighed by how long each video is rather than
            # counting a two-minute video the same as a twenty-minute one.
            ItemDurations = @($displayItems | ForEach-Object { [double]$_.Duration })
            DurationSeconds = [double](@($displayItems | ForEach-Object { [double]$_.Duration }) | Measure-Object -Sum).Sum
            CurrentItem = 0
            ItemPercent = 0.0
            Stage = ''
            Message = ''
            MotionQuality = Get-ComboText $MotionQualityCombo
            Encoder = $encoder
            FilterBackend = if ($null -eq $script:FilterBackend) { 'cpu' } else { [string]$script:FilterBackend }
            HistoryId = $HistoryId
        }
        $script:NowRenderingThumb = $null
        Show-BatchRun -Run ([pscustomobject]@{
            Items = $displayItems.ToArray()
            ProjectPaths = @($projectPaths)
            HistoryId = $HistoryId
            Running = $true
            Result = ''
            ResultText = ''
            MeasuredSpeed = 0.0
        })
        $RenderProgress.Value = 0
        $script:LastHistoryProgressBucket = -1
        Set-RenderControls $true
        $StatusText.Text = "Starting batch of $($prepared.Count) projects..."
        $script:RenderProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentLine -PassThru -WindowStyle Hidden
        $renderTimer.Start()
    }
    catch {
        Write-ToolDiagnostic 'Batch preparation failed.' $_.Exception
        if ($null -ne $script:BatchRun -and [bool]$script:BatchRun.Running) {
            $script:BatchRun = $null
            $RenderRowsPanel.Children.Clear()
        }
        if ($null -ne $script:RenderState -and $script:RenderState.PSObject.Properties['HistoryId']) { Update-RenderHistoryEntry -Id ([string]$script:RenderState.HistoryId) -Status 'Failed' -Progress 0 -Detail $_.Exception.Message }
        if ($null -ne $script:RenderState) { Remove-RenderArtifacts -State $script:RenderState }
        elseif (-not [string]::IsNullOrWhiteSpace($batchDirectory)) { Remove-CaptionRunDirectory $batchDirectory }
        $script:RenderProcess = $null
        $script:RenderState = $null
        Set-RenderControls $false
        Show-ErrorMessage $_.Exception.Message 'Could not start batch'
    }
}

function Complete-BatchRender {
    $state = $script:RenderState
    $process = $script:RenderProcess
    $result = 'Failed'
    $resultText = ''
    try {
        $renderTimer.Stop()
        $process.WaitForExit(); $process.Refresh()
        # The last progress the worker wrote says which video it reached, so
        # every video before it is known to be finished whatever happened next.
        $lastProgress = Read-BatchProgress $state.ProgressPath
        if ($lastProgress.Item -ge 0) { Update-BatchRunProgress -ItemIndex $lastProgress.Item -ItemPercent $lastProgress.ItemPercent -Stage $lastProgress.Stage }
        if ($script:CancelRequested) {
            Update-RenderHistoryEntry -Id ([string]$state.HistoryId) -Status 'Paused' -Progress ([int]$RenderProgress.Value) -Detail 'Batch paused by the user; completed videos and segments were kept.'
            $StatusText.Text = 'Batch paused. Finished videos and resumable segments were kept.'
            $result = 'Paused'
            $resultText = 'Batch paused. Finished videos and finished stretches were kept; Resume carries on from there.'
        }
        else {
            if ($process.ExitCode -ne 0) {
                $details = 'The batch worker stopped before all projects completed.'
                if (Test-Path -LiteralPath $state.ErrorPath -PathType Leaf) {
                    $raw = Get-Content -LiteralPath $state.ErrorPath -Raw -ErrorAction SilentlyContinue
                    # The worker's stack is kept in the log for diagnosis, below a
                    # marker; the person is shown what went wrong, not where.
                    if (-not [string]::IsNullOrWhiteSpace($raw)) { $details = ($raw -split '(?m)^--- worker stack ---')[0].Trim() }
                }
                throw $details
            }
            $RenderProgress.Value = 100
            $script:FinalOutputPath = $state.DestinationPath
            $OpenFolderButton.IsEnabled = $true
            Update-RenderHistoryEntry -Id ([string]$state.HistoryId) -Status 'Completed' -Progress 100 -Detail "Completed $(@($state.OutputPaths).Count) videos."
            $StatusText.Text = "Batch completed: $(@($state.OutputPaths).Count) videos."
            $result = 'Completed'
            $resultText = "Batch completed: $(@($state.OutputPaths).Count) videos."
            if ($null -ne $script:BatchRun) {
                foreach ($item in @($script:BatchRun.Items)) { Set-BatchItemDone -Item $item; Update-RenderRowVisual -Item $item }
            }
            # How fast this computer really renders, for the next estimate. A
            # short run, or one that mostly reused finished stretches, says
            # little about that, so only a batch of some length counts.
            $elapsed = ([DateTime]::UtcNow - [DateTime]$state.StartedUtc).TotalSeconds
            $videoSeconds = [double]$state.DurationSeconds
            if ($elapsed -ge 300 -and $videoSeconds -gt 0) {
                $measured = $videoSeconds / $elapsed
                $quality = [string]$state.MotionQuality
                $previous = if ($script:RenderSpeeds.ContainsKey($quality)) { [double]$script:RenderSpeeds[$quality] } else { 0.0 }
                $script:RenderSpeeds[$quality] = if ($previous -gt 0) { ($previous + $measured) / 2.0 } else { $measured }
                if ($null -ne $script:BatchRun) { $script:BatchRun.MeasuredSpeed = $measured }
            }
        }
    }
    catch {
        Write-ToolDiagnostic 'Batch rendering failed.' $_.Exception
        if ($null -ne $state -and $state.PSObject.Properties['FilterBackend'] -and [string]$state.FilterBackend -eq 'vulkan' -and
            $_.Exception.Message -match '(?i)vulkan|libplacebo|hwupload|hardware device|device lost|device creation') {
            Set-CpuFilterFallback
            Write-ToolDiagnostic 'Vulkan motion effects failed during a batch and were disabled for subsequent renders.'
        }
        if ($null -ne $state -and $state.PSObject.Properties['HistoryId']) { Update-RenderHistoryEntry -Id ([string]$state.HistoryId) -Status 'Failed' -Progress ([int]$RenderProgress.Value) -Detail $_.Exception.Message }
        Show-ErrorMessage "$($_.Exception.Message)`r`n`r`nCompleted videos and resumable segments were kept." 'Batch rendering stopped'
        $StatusText.Text = 'Batch stopped. Resume carries on from the video that stopped.'
        $result = 'Failed'
        $resultText = 'Batch stopped. Finished videos were kept; Resume carries on from the video that stopped.'
    }
    finally {
        if ($null -ne $state) { Remove-RenderArtifacts -State $state -KeepErrorLog ($process.ExitCode -ne 0) }
        $thumb = $script:NowRenderingThumb
        if ($null -ne $thumb -and -not [string]::IsNullOrWhiteSpace([string]$thumb.OutputPath)) { Remove-Item -LiteralPath ([string]$thumb.OutputPath) -Force -ErrorAction SilentlyContinue }
        $script:NowRenderingThumb = $null
        $run = $script:BatchRun
        if ($null -ne $run) {
            $run.Running = $false
            $run.Result = $result
            $run.ResultText = $resultText
            # The video that was being rendered when the batch stopped.
            foreach ($item in @($run.Items)) {
                if ($item.State -eq 'Rendering') {
                    $item.State = if ($result -eq 'Paused') { 'Paused' } else { 'Failed' }
                    Update-RenderRowVisual -Item $item
                }
            }
        }
        $script:RenderProcess = $null
        $script:RenderState = $null
        Save-QueueState
        Save-UserSettings
        Set-RenderControls $false
        Update-BatchHeader
        Update-NowRenderingPanel
    }
}

function Start-VideoRender {
    param([ValidateSet('Preview', 'Final')][string]$Kind)
    if ($null -ne $script:RenderProcess -and -not $script:RenderProcess.HasExited) {
        return
    }

    try {
        Assert-FFmpegAvailable
        $settings = Get-UiSettings

        $imageFolder = $ImageFolderText.Text.Trim()
        $audioPath = $AudioText.Text.Trim()
        $watermarkPath = $WatermarkText.Text.Trim()
        if (-not (Test-Path -LiteralPath $imageFolder -PathType Container)) {
            throw 'Select a valid image folder.'
        }
        if (-not (Test-VoiceoverFile $audioPath)) {
            throw 'Select a valid voiceover file.'
        }
        $script:CaptionPath = Get-CaptionCachePath -AudioPath $audioPath -DataRoot $script:DataRoot
        if ($settings.CaptionMode -ne 'Off' -and -not (Test-Path -LiteralPath $script:CaptionPath -PathType Leaf)) {
            $script:PendingRenderAfterCaptions = $Kind
            [void](Start-CaptionGeneration)
            return
        }
        if (-not (Test-Path -LiteralPath $watermarkPath -PathType Leaf) -or
            @('.mov', '.mp4') -notcontains [IO.Path]::GetExtension($watermarkPath).ToLowerInvariant()) {
            throw 'Select a valid MOV or MP4 watermark file.'
        }
        if (-not (Test-VideoStream $watermarkPath)) {
            throw 'FFprobe could not find a readable video stream in the watermark file.'
        }

        $images = @(Get-ValidatedImages $imageFolder)
        $duration = Get-MediaDurationSeconds -FfprobePath $script:FfprobePath -MediaPath $audioPath
        $script:AudioDurationSeconds = $duration
        Update-Estimate
        Ensure-TimelinePlan -Images $images -Duration $duration -Settings $settings
        $fingerprint = Get-CurrentPreviewFingerprint -Settings $settings

        if ($Kind -eq 'Final') {
            if (-not $script:PreviewValid -or $script:PreviewFingerprint -ne $fingerprint) {
                throw 'The preview is missing or outdated. Generate a new preview before final rendering.'
            }
            $destinationPath = $OutputText.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($destinationPath)) {
                throw 'Choose a final output filename.'
            }
            if ([IO.Path]::GetExtension($destinationPath).ToLowerInvariant() -ne '.mp4') {
                throw 'The final output filename must end with .mp4.'
            }
            $destinationDirectory = Split-Path -Parent $destinationPath
            if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
                throw 'The selected output folder does not exist.'
            }
            if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
                $choice = [System.Windows.MessageBox]::Show(
                    $window,
                    "The output file already exists:`r`n`r`n$destinationPath`r`n`r`nReplace it after rendering succeeds?",
                    'Confirm replacement',
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Warning
                )
                if ($choice -ne [System.Windows.MessageBoxResult]::Yes) {
                    return
                }
            }
            $renderFrames = [int]$script:CurrentPlan.TotalFrames
        }
        else {
            $destinationPath = $script:PreviewPath
            $renderFrames = [Math]::Min(60 * [int]$script:CurrentPlan.Fps, [int]$script:CurrentPlan.TotalFrames)
            Stop-PreviewPlayback
            $PreviewMedia.Source = $null
        }

        $encoder = Select-AvailableEncoder
        $filterBackend = Select-AvailableFilterBackend -Timeline $script:CurrentPlan -Settings $settings -WatermarkPath $watermarkPath
        if ($Kind -eq 'Final') {
            $finalFingerprint = Get-CurrentFinalFingerprint -Settings $settings -PreviewFingerprint $fingerprint -CaptionPath $script:CaptionPath
            Start-ResumableFinalRender -Settings $settings -Fingerprint $finalFingerprint -DestinationPath $destinationPath -Encoder $encoder -AudioPath $audioPath -WatermarkPath $watermarkPath
            return
        }
        $useOpenClEffects = $encoder -eq 'h264_nvenc' -and $null -ne $script:OpenClDevice -and (Test-Path -LiteralPath $script:ScreenKernelPath -PathType Leaf)
        if ($useOpenClEffects) {
            $definition = New-FilterGraph `
                -Timeline $script:CurrentPlan `
                -RenderFrames $renderFrames `
                -ZoomMaximumPercent $settings.ZoomMaximum `
                -BlurAmount $settings.BlurAmount `
                -BackgroundBrightnessPercent $settings.BackgroundBrightness `
                -SubtitlePath '' `
                -CaptionPreset $settings.CaptionPreset `
                -OpenClScreenKernelPath $script:ScreenKernelPath `
                -CrossfadeSeconds (Get-CrossfadeSeconds $settings) `
                -OverscanScale (Get-OverscanScale $settings) `
                -Width 1920 -Height 1080
        }
        elseif ($filterBackend -eq 'vulkan') {
            $definition = New-VulkanFilterGraph `
                -Timeline $script:CurrentPlan `
                -RenderFrames $renderFrames `
                -ZoomMaximumPercent $settings.ZoomMaximum `
                -BlurAmount $settings.BlurAmount `
                -BackgroundBrightnessPercent $settings.BackgroundBrightness `
                -SubtitlePath '' `
                -CaptionPreset $settings.CaptionPreset `
                -HardwareOutputFrames ($encoder -eq 'h264_vulkan') `
                -CrossfadeSeconds (Get-CrossfadeSeconds $settings) `
                -OverscanScale (Get-OverscanScale $settings) `
                -Width 1920 -Height 1080
        }
        else {
            $definition = New-FilterGraph `
                -Timeline $script:CurrentPlan `
                -RenderFrames $renderFrames `
                -ZoomMaximumPercent $settings.ZoomMaximum `
                -BlurAmount $settings.BlurAmount `
                -BackgroundBrightnessPercent $settings.BackgroundBrightness `
                -SubtitlePath '' `
                -CaptionPreset $settings.CaptionPreset `
                -CrossfadeSeconds (Get-CrossfadeSeconds $settings) `
                -OverscanScale (Get-OverscanScale $settings) `
                -Width 1920 -Height 1080
        }

        $runId = [guid]::NewGuid().ToString('N')
        $runDirectory = Join-Path $script:DataRoot "run-$runId"
        New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
        $filterPath = Join-Path $runDirectory 'filter.txt'
        $progressPath = Join-Path $runDirectory 'progress.txt'
        $errorPath = Join-Path $runDirectory 'ffmpeg-error.log'
        [IO.File]::WriteAllText($filterPath, $definition.FilterText, [Text.UTF8Encoding]::new($false))

        if ($Kind -eq 'Preview') {
            $stagingPath = Join-Path $runDirectory 'preview-rendering.mp4'
        }
        else {
            $baseName = [IO.Path]::GetFileNameWithoutExtension($destinationPath)
            $stagingPath = Join-Path (Split-Path -Parent $destinationPath) ".$baseName.rendering-$runId.mp4"
        }

        $arguments = [System.Collections.Generic.List[string]]::new()
        foreach ($value in @('-y', '-hide_banner', '-loglevel', 'error', '-nostats', '-progress', $progressPath)) {
            $arguments.Add($value)
        }
        if ($useOpenClEffects) {
            foreach ($value in @(
                    '-init_hw_device', "opencl=screencl:$($script:OpenClDevice)",
                    '-filter_hw_device', 'screencl')) {
                $arguments.Add($value)
            }
        }
        elseif ($filterBackend -eq 'vulkan') {
            foreach ($value in @(
                    '-init_hw_device', "vulkan=slideshowgpu:$($script:FilterVulkanDeviceIndex)",
                    '-filter_hw_device', 'slideshowgpu')) {
                $arguments.Add($value)
            }
        }
        foreach ($value in @('-i', $audioPath, '-stream_loop', '-1', '-i', $watermarkPath)) {
            $arguments.Add($value)
        }
        foreach ($imagePath in $definition.ImageInputs) {
            $arguments.Add('-i')
            $arguments.Add($imagePath)
        }
        foreach ($value in @('-filter_complex_script', $filterPath, '-map', '[vout]', '-map', '0:a:0')) {
            $arguments.Add($value)
        }
        foreach ($value in (Get-EncodingArguments -Encoder $encoder -Quality $settings.Quality -Fps ([int]$script:CurrentPlan.Fps))) {
            $arguments.Add($value)
        }
        $audioBitrate = if ($settings.Quality -eq 'YouTube') { '384k' } else { '160k' }
        # Match the final render's playback level so the preview is worth
        # judging by ear. The final pass measures the whole voiceover first;
        # the preview uses the cheaper single pass to stay responsive.
        # -r keeps the written duration honest. A caption-free final render can
        # drop this exact file in as its first segment, and a segment that
        # reports itself one frame short collides with the one joined after it.
        foreach ($value in @(
                '-r', [string][int]$script:CurrentPlan.Fps,
                '-frames:v', [string]$renderFrames,
                '-af', 'loudnorm=I=-14:TP=-1.5:LRA=11',
                '-c:a', 'aac', '-b:a', $audioBitrate, '-ar', '48000', '-ac', '2',
                '-shortest', '-movflags', '+faststart', $stagingPath)) {
            $arguments.Add($value)
        }

        $argumentLine = Join-ProcessArguments $arguments.ToArray()
        $script:CancelRequested = $false
        $script:RenderState = [pscustomobject]@{
            Kind = $Kind
            RunDirectory = $runDirectory
            ProgressPath = $progressPath
            ErrorPath = $errorPath
            StagingPath = $stagingPath
            DestinationPath = $destinationPath
            DurationSeconds = $definition.DurationSeconds
            Fingerprint = $fingerprint
            Encoder = $encoder
            FilterBackend = $filterBackend
            CaptionPath = if ($settings.CaptionMode -ne 'Off') { $script:CaptionPath } else { '' }
            CaptionMode = [string]$settings.CaptionMode
            CaptionWordsPerLine = [int]$settings.CaptionWordsPerLine
        }
        $RenderProgress.Value = 0
        $script:LastHistoryProgressBucket = -1
        $StatusText.Text = "Starting $($Kind.ToLowerInvariant()) render with $encoder..."
        Set-RenderControls $true

        $script:RenderProcess = Start-Process `
            -FilePath $script:FfmpegPath `
            -ArgumentList $argumentLine `
            -PassThru `
            -WindowStyle Hidden `
            -RedirectStandardError $errorPath
        Write-ToolDiagnostic "$Kind render started. Encoder=$encoder PID=$($script:RenderProcess.Id)"
        $renderTimer.Start()
    }
    catch {
        Write-ToolDiagnostic 'Render startup failed.' $_.Exception
        if ($null -ne $script:RenderState -and $script:RenderState.PSObject.Properties['HistoryId']) { Update-RenderHistoryEntry -Id ([string]$script:RenderState.HistoryId) -Status 'Failed' -Progress 0 -Detail $_.Exception.Message }
        if ($null -ne $script:RenderState) {
            Remove-RenderArtifacts -State $script:RenderState
        }
        $script:RenderProcess = $null
        $script:RenderState = $null
        Set-RenderControls $false
        Show-ErrorMessage $_.Exception.Message
        $StatusText.Text = 'Could not start rendering.'
    }
}

function Read-ProgressSeconds {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return 0.0
    }
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $reader = [IO.StreamReader]::new($stream)
            $text = $reader.ReadToEnd()
            $reader.Dispose()
        }
        finally {
            $stream.Dispose()
        }
        $matches = [regex]::Matches($text, '(?m)^out_time_us=(\d+)')
        if ($matches.Count -gt 0) {
            return [double]$matches[$matches.Count - 1].Groups[1].Value / 1000000.0
        }
    }
    catch {}
    return 0.0
}

function Remove-RenderArtifacts {
    param([psobject]$State, [bool]$KeepErrorLog = $false)
    if ($null -eq $State) {
        return
    }
    if ($State.PSObject.Properties['StagingPath'] -and
        -not [string]::IsNullOrWhiteSpace([string]$State.StagingPath) -and
        (Test-Path -LiteralPath $State.StagingPath -PathType Leaf)) {
        Remove-Item -LiteralPath $State.StagingPath -Force -ErrorAction SilentlyContinue
    }
    if ($KeepErrorLog -and (Test-Path -LiteralPath $State.ErrorPath -PathType Leaf)) {
        Copy-Item -LiteralPath $State.ErrorPath -Destination $script:LastErrorPath -Force -ErrorAction SilentlyContinue
    }
    if ($State.RunDirectory -and (Test-Path -LiteralPath $State.RunDirectory -PathType Container)) {
        $resolvedDataRoot = [IO.Path]::GetFullPath($script:DataRoot).TrimEnd('\') + '\'
        $resolvedRun = [IO.Path]::GetFullPath($State.RunDirectory).TrimEnd('\') + '\'
        if ($resolvedRun.StartsWith($resolvedDataRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $State.RunDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Complete-VideoRender {
    $state = $null
    $process = $null
    try {
        $renderTimer.Stop()
        $state = $script:RenderState
        $process = $script:RenderProcess
        if ($null -eq $state -or $null -eq $process) {
            throw 'The render completion state was unexpectedly unavailable.'
        }

        # Start-Process can report HasExited before its managed Process object
        # has populated ExitCode. WaitForExit synchronizes that final state.
        $process.WaitForExit()
        $process.Refresh()
        $exitCode = [int]$process.ExitCode
        Write-ToolDiagnostic "$($state.Kind) render process exited. PID=$($process.Id) ExitCode=$exitCode"

        if ($script:CancelRequested) {
            if ($state.PSObject.Properties['HistoryId']) { Update-RenderHistoryEntry -Id ([string]$state.HistoryId) -Status 'Paused' -Progress ([int]$RenderProgress.Value) -Detail 'Paused by the user; completed 60-second segments were kept.' }
            Remove-RenderArtifacts -State $state
            $RenderProgress.Value = 0
            if ($state.PSObject.Properties['IsWorker'] -and [bool]$state.IsWorker) {
                $StatusText.Text = 'Render paused. Completed 60-second segments were kept; click Render / Resume Final to continue.'
            }
            else {
                $StatusText.Text = 'Render cancelled. Incomplete output was removed.'
            }
            return
        }

        $isWorker = ($state.PSObject.Properties['IsWorker'] -and [bool]$state.IsWorker)
        $expectedOutputPath = if ($isWorker) { $state.DestinationPath } else { $state.StagingPath }
        if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $expectedOutputPath -PathType Leaf)) {
            $errorText = ''
            if (Test-Path -LiteralPath $state.ErrorPath -PathType Leaf) {
                $rawError = Get-Content -LiteralPath $state.ErrorPath -Raw -ErrorAction SilentlyContinue
                if ($null -ne $rawError) {
                    $errorText = $rawError.Trim()
                }
            }
            Remove-RenderArtifacts -State $state -KeepErrorLog $true
            if ($errorText.Length -gt 2500) {
                $errorText = $errorText.Substring($errorText.Length - 2500)
            }
            if ([string]::IsNullOrWhiteSpace($errorText)) {
                $errorText = if ($exitCode -eq 0) {
                    "Rendering exited successfully, but the expected output file was not found:`r`n$expectedOutputPath"
                }
                else {
                    "FFmpeg exited with code $exitCode."
                }
            }
            if ($state.PSObject.Properties['FilterBackend'] -and [string]$state.FilterBackend -eq 'vulkan' -and
                $errorText -match '(?i)vulkan|libplacebo|hwupload|hardware device|device lost|device creation') {
                Set-CpuFilterFallback
                $errorText += "`r`n`r`nGPU motion effects were disabled for this machine. Retry the render; it will use the unchanged CPU quality path."
                Write-ToolDiagnostic 'Vulkan motion effects failed and were disabled for subsequent renders.'
            }
            if ($state.PSObject.Properties['HistoryId']) { Update-RenderHistoryEntry -Id ([string]$state.HistoryId) -Status 'Failed' -Progress ([int]$RenderProgress.Value) -Detail $errorText }
            Show-ErrorMessage "$errorText`r`n`r`nA full error log was saved to:`r`n$script:LastErrorPath" 'Rendering failed'
            $StatusText.Text = 'Rendering failed. Incomplete output was removed.'
            return
        }

        if ($state.Kind -eq 'Preview') {
            Stop-PreviewPlayback
            $PreviewMedia.Source = $null
            if (Test-Path -LiteralPath $state.DestinationPath -PathType Leaf) {
                Remove-Item -LiteralPath $state.DestinationPath -Force
            }
            Move-Item -LiteralPath $state.StagingPath -Destination $state.DestinationPath -Force
            $PreviewMedia.Source = [uri]$state.DestinationPath
            $PreviewMedia.Position = [TimeSpan]::Zero
            $script:PreviewFingerprint = $state.Fingerprint
            $script:PreviewValid = $true
            # A video opened from the queue keeps the timeline this preview was
            # made with, so the batch renders exactly what was watched here.
            $queueRow = Get-QueueRow -Id $script:QueuePreviewRowId
            if ($null -ne $queueRow -and
                [string]::Equals(([string]$queueRow.ImageFolder).Trim(), $ImageFolderText.Text.Trim(), [StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals(([string]$queueRow.AudioPath).Trim(), $AudioText.Text.Trim(), [StringComparison]::OrdinalIgnoreCase)) {
                $queueRow.PreviewPlan = $script:CurrentPlan
                $queueRow.PreviewPlanSignature = [string]$script:PlanSignature
            }
            $script:LiveCaptionCacheSignature = ''
            Refresh-LiveCaptionEntries
            Update-LiveCaptionText
            $FinalButton.IsEnabled = $true
            $StatusText.Text = '1080p preview ready. Use the player, then render the final video.'
            Write-ToolDiagnostic "Preview finalized at $($state.DestinationPath)"
        }
        else {
            if (-not $isWorker) {
                Move-Item -LiteralPath $state.StagingPath -Destination $state.DestinationPath -Force
                if ($state.PSObject.Properties['CaptionPath'] -and
                    $state.PSObject.Properties['CaptionMode'] -and
                    [string]$state.CaptionMode -in @('SRT only', 'Burned + SRT') -and
                    -not [string]::IsNullOrWhiteSpace([string]$state.CaptionPath) -and
                    (Test-Path -LiteralPath $state.CaptionPath -PathType Leaf)) {
                    $wordsPerLine = if ($state.PSObject.Properties['CaptionWordsPerLine']) { [int]$state.CaptionWordsPerLine } else { 8 }
                    [void](Copy-SrtWithWordWrapping -SourcePath $state.CaptionPath -DestinationPath ([IO.Path]::ChangeExtension($state.DestinationPath, '.srt')) -MaxWordsPerLine $wordsPerLine)
                }
            }
            $script:FinalOutputPath = $state.DestinationPath
            $OpenFolderButton.IsEnabled = $true
            # A queued video rendered on its own here is finished in the queue
            # too, so Render all does not make it a second time.
            $finishedInQueue = $false
            foreach ($queueRow in $script:QueueRows) {
                if (-not [bool]$queueRow.Done -and [string]::Equals((Get-QueueRowOutputPath -Row $queueRow), [string]$state.DestinationPath, [StringComparison]::OrdinalIgnoreCase)) {
                    $queueRow.Done = $true
                    $queueRow.DoneOutput = [string]$state.DestinationPath
                    $finishedInQueue = $true
                }
            }
            if ($finishedInQueue) { Complete-QueueChange }
            if ($state.PSObject.Properties['HistoryId']) { Update-RenderHistoryEntry -Id ([string]$state.HistoryId) -Status 'Completed' -Progress 100 -Detail 'Final video completed successfully.' }
            $StatusText.Text = "Final video completed: $($state.DestinationPath)"
            Write-ToolDiagnostic "Final output finalized at $($state.DestinationPath)"
        }
        $RenderProgress.Value = 100
        Remove-RenderArtifacts -State $state
    }
    catch {
        Write-ToolDiagnostic 'Render completion or output finalization failed.' $_.Exception
        if ($null -ne $state -and $state.PSObject.Properties['HistoryId']) { Update-RenderHistoryEntry -Id ([string]$state.HistoryId) -Status 'Failed' -Progress ([int]$RenderProgress.Value) -Detail $_.Exception.Message }
        if ($null -ne $state) {
            Remove-RenderArtifacts -State $state -KeepErrorLog $true
        }
        Show-ErrorMessage "Rendering completed, but the output could not be finalized:`r`n`r`n$($_.Exception.Message)`r`n`r`nDiagnostic log:`r`n$script:DiagnosticLogPath"
        $StatusText.Text = 'Output finalization failed.'
    }
    finally {
        $script:RenderProcess = $null
        $script:RenderState = $null
        Set-RenderControls $false
    }
}

function Save-Project {
    try {
        $settings = Get-UiSettings
        $path = $script:CurrentProjectPath
        if ([string]::IsNullOrWhiteSpace($path)) {
            $path = Select-SaveFile -Title 'Save slideshow project' -Filter 'Slideshow project (*.svp.json)|*.svp.json' -DefaultExtension '.svp.json'
            if (-not $path) { return }
        }

        $project = [ordered]@{
            SchemaVersion = 1
            ImageFolder = $ImageFolderText.Text.Trim()
            AudioPath = $AudioText.Text.Trim()
            WatermarkPath = $WatermarkText.Text.Trim()
            OutputPath = $OutputText.Text.Trim()
            Settings = $settings
            PlanSignature = $script:PlanSignature
            Timeline = $script:CurrentPlan
        }
        $json = $project | ConvertTo-Json -Depth 12
        [IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))
        $script:CurrentProjectPath = $path
        $StatusText.Text = "Project saved: $path"
    }
    catch {
        Show-ErrorMessage $_.Exception.Message 'Could not save project'
    }
}

function Resolve-MissingMediaFile {
    param([string]$Path, [string]$Title, [string]$Filter)
    if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $Path
    }
    $choice = [System.Windows.MessageBox]::Show(
        $window,
        "A saved project file is missing:`r`n`r`n$Path`r`n`r`nLocate it now?",
        'Missing project file',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    if ($choice -ne [System.Windows.MessageBoxResult]::Yes) {
        return $Path
    }
    $replacement = Select-OpenFile -Title $Title -Filter $Filter
    if ($replacement) { return $replacement }
    return $Path
}

function Open-Project {
    $path = Select-OpenFile -Title 'Open slideshow project' -Filter 'Slideshow project (*.svp.json)|*.svp.json|JSON files (*.json)|*.json'
    if (-not $path) { return }

    try {
        $project = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ([int]$project.SchemaVersion -ne 1) {
            throw 'This project version is not supported.'
        }

        $imageFolder = [string]$project.ImageFolder
        if (-not (Test-Path -LiteralPath $imageFolder -PathType Container)) {
            $choice = [System.Windows.MessageBox]::Show(
                $window,
                "The saved image folder is missing:`r`n`r`n$imageFolder`r`n`r`nLocate it now?",
                'Missing image folder',
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Question
            )
            if ($choice -eq [System.Windows.MessageBoxResult]::Yes) {
                $selected = Select-Folder -Description 'Locate the project image folder'
                if ($selected) { $imageFolder = $selected }
            }
        }

        $audioPath = Resolve-MissingMediaFile -Path ([string]$project.AudioPath) -Title 'Locate voiceover' -Filter $script:VoiceoverFilter
        $watermarkPath = Resolve-MissingMediaFile -Path ([string]$project.WatermarkPath) -Title 'Locate watermark' -Filter 'Video files (*.mov;*.mp4)|*.mov;*.mp4'

        $script:IsLoading = $true
        try {
            $ImageFolderText.Text = $imageFolder
            $AudioText.Text = $audioPath
            $WatermarkText.Text = $watermarkPath
            $OutputText.Text = [string]$project.OutputPath
            $MinimumDurationText.Text = [string]$project.Settings.MinimumDuration
            $MaximumDurationText.Text = [string]$project.Settings.MaximumDuration
            $ZoomText.Text = [string]$project.Settings.ZoomMaximum
            $BlurSlider.Value = [double]$project.Settings.BlurAmount
            $BrightnessSlider.Value = [double]$project.Settings.BackgroundBrightness
            Set-ComboText $QualityCombo ([string]$project.Settings.Quality)
            if ($null -ne $project.Settings.PSObject.Properties['CaptionMode']) { Set-ComboText $CaptionModeCombo ([string]$project.Settings.CaptionMode) }
            if ($null -ne $project.Settings.PSObject.Properties['CaptionPreset']) { Set-ComboText $CaptionPresetCombo ([string]$project.Settings.CaptionPreset) }
            if ($null -ne $project.Settings.PSObject.Properties['CaptionFont']) {
                Set-ComboText $CaptionFontCombo ([string]$project.Settings.CaptionFont)
                $CaptionSizeSlider.Value = [double]$project.Settings.CaptionFontSize
                $CaptionBoldCheckBox.IsChecked = [bool]$project.Settings.CaptionBold
                $CaptionTextColorText.Text = [string]$project.Settings.CaptionTextColor
                $CaptionOutlineColorText.Text = [string]$project.Settings.CaptionOutlineColor
                $CaptionOutlineSlider.Value = [double]$project.Settings.CaptionOutlineWidth
                $CaptionShadowSlider.Value = [double]$project.Settings.CaptionShadow
                $CaptionBackgroundColorText.Text = [string]$project.Settings.CaptionBackgroundColor
                $CaptionBackgroundOpacitySlider.Value = [double]$project.Settings.CaptionBackgroundOpacity
                Set-ComboText $CaptionAlignmentCombo ([string]$project.Settings.CaptionAlignment)
                $CaptionPositionXSlider.Value = [double]$project.Settings.CaptionPositionX
                $CaptionPositionYSlider.Value = [double]$project.Settings.CaptionPositionY
                $CaptionMaxWidthSlider.Value = [double]$project.Settings.CaptionMaxWidth
                if ($project.Settings.PSObject.Properties['CaptionWordsPerLine']) { $CaptionWordsPerLineSlider.Value = [double]$project.Settings.CaptionWordsPerLine }
                $CaptionLineSpacingSlider.Value = [double]$project.Settings.CaptionLineSpacing
            }
            else { Apply-CaptionPresetToControls (Get-ComboText $CaptionPresetCombo) }
            if ($null -ne $project.Settings.Volume) { $VolumeSlider.Value = [double]$project.Settings.Volume }

            $script:CurrentPlan = $project.Timeline
            $script:PlanSignature = [string]$project.PlanSignature
            if ($null -ne $script:CurrentPlan) {
                $replacementByName = @{}
                foreach ($item in $script:CurrentPlan.Items) {
                    $originalName = [string]$item.ImageName
                    $nameKey = $originalName.ToLowerInvariant()
                    $candidate = Join-Path $imageFolder $originalName
                    if ($replacementByName.ContainsKey($nameKey)) {
                        $item.ImagePath = $replacementByName[$nameKey]
                        $item.ImageName = [IO.Path]::GetFileName($replacementByName[$nameKey])
                    }
                    elseif (Test-Path -LiteralPath $candidate -PathType Leaf) {
                        $item.ImagePath = $candidate
                        $replacementByName[$nameKey] = $candidate
                    }
                    elseif (-not (Test-Path -LiteralPath ([string]$item.ImagePath) -PathType Leaf)) {
                        $replacement = Resolve-MissingMediaFile `
                            -Path ([string]$item.ImagePath) `
                            -Title "Locate $($item.ImageName)" `
                            -Filter 'Images (*.jpg;*.jpeg;*.png;*.webp)|*.jpg;*.jpeg;*.png;*.webp'
                        $item.ImagePath = $replacement
                        if ($replacement -and (Test-Path -LiteralPath $replacement -PathType Leaf)) {
                            $item.ImageName = [IO.Path]::GetFileName($replacement)
                            $replacementByName[$nameKey] = $replacement
                        }
                    }
                    else {
                        $replacementByName[$nameKey] = [string]$item.ImagePath
                    }
                }
            }
        }
        finally {
            $script:IsLoading = $false
        }

        Update-SettingLabels
        $script:CurrentProjectPath = $path
        $script:PreviewValid = $false
        $script:PreviewFingerprint = $null
        $FinalButton.IsEnabled = $false
        Update-StoryboardUI
        $StatusText.Text = 'Project loaded. Generate a new preview before final rendering.'
    }
    catch {
        $script:IsLoading = $false
        Show-ErrorMessage $_.Exception.Message 'Could not open project'
    }
}

function Format-PlayerTime {
    param([TimeSpan]$Time)
    if ($Time.TotalHours -ge 1) {
        return $Time.ToString('hh\:mm\:ss')
    }
    return $Time.ToString('mm\:ss')
}

function Toggle-FullScreen {
    if (-not $script:IsFullScreen) {
        $script:OriginalWindowState = $window.WindowState
        $script:OriginalWindowStyle = $window.WindowStyle
        $script:OriginalSettingsWidth = $SettingsColumn.Width
        $script:OriginalNavigationWidth = $NavigationColumn.Width
        $SettingsColumn.Width = [Windows.GridLength]::new(0)
        $NavigationColumn.Width = [Windows.GridLength]::new(0)
        $StatusPanel.Visibility = [Windows.Visibility]::Collapsed
        $window.WindowStyle = [Windows.WindowStyle]::None
        $window.WindowState = [Windows.WindowState]::Maximized
        $FullScreenButton.Content = 'Exit Full Screen'
        $script:IsFullScreen = $true
    }
    else {
        $SettingsColumn.Width = $script:OriginalSettingsWidth
        $NavigationColumn.Width = $script:OriginalNavigationWidth
        $StatusPanel.Visibility = [Windows.Visibility]::Visible
        $window.WindowStyle = $script:OriginalWindowStyle
        $window.WindowState = $script:OriginalWindowState
        $FullScreenButton.Content = 'Full Screen'
        $script:IsFullScreen = $false
    }
}

function Update-RenderEta {
    # A render runs at roughly real time, so a twenty minute video is a wait of
    # the same order. A percentage does not tell anyone whether to go and make
    # a coffee; a clock time does.
    param([double]$Percent)

    if ($null -eq $script:RenderState) {
        $RenderEtaText.Text = ''
        $RenderDetailText.Text = ''
        return
    }
    if (-not $script:RenderState.PSObject.Properties['StartedUtc']) { return }

    $elapsed = ([DateTime]::UtcNow - [DateTime]$script:RenderState.StartedUtc).TotalSeconds
    if ([string]$script:RenderState.Kind -eq 'Batch' -and $script:RenderState.PSObject.Properties['ItemDurations']) {
        # A batch is weighed by seconds of video, not by count of videos:
        # after two short videos of ten, a fifth of the batch is not done.
        $total = [double]$script:RenderState.DurationSeconds
        $done = Get-BatchSecondsDone
        $batchDetail = @("$([int][Math]::Floor($Percent))% of the batch")
        if ($total -le 0 -or $done -le 1 -or $elapsed -lt 20) {
            $RenderEtaText.Text = 'estimating...'
        }
        else {
            $speed = $done / $elapsed
            $remaining = [Math]::Max(0.0, ($total - $done) / $speed)
            $finish = [DateTime]::Now.AddSeconds($remaining)
            $RenderEtaText.Text = "$(Format-LongDuration $remaining) left, finishes $($finish.ToString('HH:mm'))"
            $batchDetail += ('{0:0.0}x real time' -f $speed)
        }
        if ($script:RenderState.PSObject.Properties['Encoder']) { $batchDetail += [string]$script:RenderState.Encoder }
        $RenderDetailText.Text = $batchDetail -join '  |  '
        return
    }
    # Below a few percent the rate is dominated by start-up, and an estimate
    # made from it would swing wildly and then settle. Better to say nothing.
    if ($Percent -lt 3.0 -or $elapsed -lt 5.0) {
        $RenderEtaText.Text = 'estimating...'
        return
    }

    $remaining = ($elapsed / $Percent) * (100.0 - $Percent)
    $finish = [DateTime]::Now.AddSeconds($remaining)
    $left = if ($remaining -ge 90) { "about $([int][Math]::Round($remaining / 60.0)) min left" }
            elseif ($remaining -ge 45) { 'about a minute left' }
            else { 'less than a minute left' }
    $RenderEtaText.Text = "$left, finishes $($finish.ToString('HH:mm'))"

    $detail = @()
    if ($script:RenderState.PSObject.Properties['Lanes'] -and [int]$script:RenderState.Lanes -gt 1) {
        $detail += "$([int]$script:RenderState.Lanes) segments at once"
    }
    if ($script:RenderState.PSObject.Properties['DurationSeconds'] -and [double]$script:RenderState.DurationSeconds -gt 0 -and $elapsed -gt 0) {
        $done = ([double]$script:RenderState.DurationSeconds) * ($Percent / 100.0)
        $detail += ('{0:0.0}x real time' -f ($done / $elapsed))
    }
    if ($script:RenderState.PSObject.Properties['Encoder']) { $detail += [string]$script:RenderState.Encoder }
    $RenderDetailText.Text = $detail -join '  |  '
}

$renderTimer = [Windows.Threading.DispatcherTimer]::new()
$renderTimer.Interval = [TimeSpan]::FromMilliseconds(350)
$renderTimer.Add_Tick({
    try {
        if ($null -eq $script:RenderProcess -or $null -eq $script:RenderState) {
            $renderTimer.Stop()
            return
        }
        if ($script:RenderState.Kind -eq 'Captions') {
            $captionProgress = Read-CaptionProgress $script:RenderState.ProgressPath
            $percentage = [Math]::Min(99.5, [Math]::Max(0, $captionProgress.Percent))
            $RenderProgress.Value = $percentage
            $StatusText.Text = $captionProgress.Message
            if (-not $script:RenderState.PSObject.Properties['IsSingleVoiceover'] -or [bool]$script:RenderState.IsSingleVoiceover) {
                $CaptionStatusText.Text = "$($captionProgress.Message) ($([Math]::Floor($percentage))%)"
            }
        }
        elseif ($script:RenderState.Kind -eq 'Batch') {
            # Which video the worker is on and how far into it, for the table,
            # the panel beside it and the finish time.
            $batchProgress = Read-BatchProgress $script:RenderState.ProgressPath
            $percentage = [Math]::Min(99.5, [Math]::Max(0, $batchProgress.Percent))
            $RenderProgress.Value = $percentage
            if ($batchProgress.Item -ge 0) {
                $script:RenderState.CurrentItem = $batchProgress.Item
                $script:RenderState.ItemPercent = $batchProgress.ItemPercent
                $script:RenderState.Stage = $batchProgress.Stage
                Update-BatchRunProgress -ItemIndex $batchProgress.Item -ItemPercent $batchProgress.ItemPercent -Stage $batchProgress.Stage
            }
            $script:RenderState.Message = $batchProgress.Message
            $items = if ($null -ne $script:BatchRun) { @($script:BatchRun.Items) } else { @() }
            $current = [int]$script:RenderState.CurrentItem
            if ($script:CancelRequested) { $StatusText.Text = 'Pausing the batch...' }
            elseif ($items.Count -gt 0 -and $current -ge 0 -and $current -lt $items.Count) {
                $StatusText.Text = "Video $($current + 1) of $($items.Count)  -  $($items[$current].Title)"
            }
            else { $StatusText.Text = "$($batchProgress.Message) ($([Math]::Floor($percentage))%)" }
            Update-NowRenderingPanel
        }
        elseif ($script:RenderState.PSObject.Properties['IsWorker'] -and [bool]$script:RenderState.IsWorker) {
            $workerProgress = Read-CaptionProgress $script:RenderState.ProgressPath
            $percentage = [Math]::Min(99.5, [Math]::Max(0, $workerProgress.Percent))
            $RenderProgress.Value = $percentage
            $StatusText.Text = "$($workerProgress.Message) ($([Math]::Floor($percentage))%)"
        }
        else {
            $seconds = Read-ProgressSeconds $script:RenderState.ProgressPath
            $percentage = [Math]::Min(99.5, [Math]::Max(0, ($seconds / $script:RenderState.DurationSeconds) * 100.0))
            $RenderProgress.Value = $percentage
            $StatusText.Text = "$($script:RenderState.Kind) rendering - $([Math]::Floor($percentage))% - $($script:RenderState.Encoder)"
        }
        Update-RenderEta -Percent $percentage
        if ($script:RenderState.PSObject.Properties['HistoryId']) {
            $bucket = [int][Math]::Floor($percentage / 5.0)
            if ($bucket -ne $script:LastHistoryProgressBucket) {
                $script:LastHistoryProgressBucket = $bucket
                Update-RenderHistoryEntry -Id ([string]$script:RenderState.HistoryId) -Status 'Rendering' -Progress ([int][Math]::Floor($percentage)) -Detail $StatusText.Text
            }
        }
        $script:RenderProcess.Refresh()
        if ($script:RenderProcess.HasExited) {
            if ($script:RenderState.Kind -eq 'Captions') {
                Complete-CaptionGeneration
            }
            elseif ($script:RenderState.Kind -eq 'Batch') {
                Complete-BatchRender
            }
            else {
                Complete-VideoRender
            }
        }
    }
    catch {
        $renderTimer.Stop()
        Write-ToolDiagnostic 'Unhandled render-progress error.' $_.Exception
        Show-ErrorMessage "The render monitor encountered an error, but the tool will remain open:`r`n`r`n$($_.Exception.Message)`r`n`r`nDiagnostic log:`r`n$script:DiagnosticLogPath"
    }
})

$playerTimer = [Windows.Threading.DispatcherTimer]::new()
$playerTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$playerTimer.Add_Tick({
    try {
        if ($PreviewMedia.NaturalDuration.HasTimeSpan) {
            $duration = $PreviewMedia.NaturalDuration.TimeSpan
            if ([Windows.Input.Mouse]::LeftButton -ne [Windows.Input.MouseButtonState]::Pressed) {
                $SeekSlider.Maximum = $duration.TotalSeconds
                $SeekSlider.Value = [Math]::Min($duration.TotalSeconds, $PreviewMedia.Position.TotalSeconds)
            }
            $TimeText.Text = "$(Format-PlayerTime $PreviewMedia.Position) / $(Format-PlayerTime $duration)"
        }
        Update-LiveCaptionText
    }
    catch {
        $playerTimer.Stop()
        Write-ToolDiagnostic 'Embedded preview-player timer failed.' $_.Exception
    }
})
$playerTimer.Start()

$BrowseImagesButton.Add_Click({
    $selected = Select-Folder -Description 'Select the folder containing this video''s images' -InitialPath $ImageFolderText.Text
    if ($selected) { $ImageFolderText.Text = $selected }
})
$BrowseAudioButton.Add_Click({
    $selected = Select-OpenFile -Title 'Select voiceover' -Filter $script:VoiceoverFilter -InitialPath $AudioText.Text
    if ($selected) {
        $AudioText.Text = $selected
        if ($script:FfprobePath) {
            try {
                $script:AudioDurationSeconds = Get-MediaDurationSeconds -FfprobePath $script:FfprobePath -MediaPath $selected
                Update-Estimate
            }
            catch {}
        }
    }
})
$BrowseWatermarkButton.Add_Click({
    $selected = Select-OpenFile -Title 'Select animated watermark' -Filter 'Video files (*.mov;*.mp4)|*.mov;*.mp4' -InitialPath $WatermarkText.Text
    if ($selected) { $WatermarkText.Text = $selected }
})
$BrowseOutputButton.Add_Click({
    $selected = Select-SaveFile -Title 'Choose final output filename' -Filter 'MP4 video (*.mp4)|*.mp4' -DefaultExtension '.mp4' -InitialPath $OutputText.Text
    if ($selected) { $OutputText.Text = $selected }
})

$ImageFolderText.Add_TextChanged({ Invalidate-Preview $true; Update-WorkflowState })
$AudioText.Add_TextChanged({
    $script:AudioDurationSeconds = 0.0
    $script:CaptionPath = $null
    $script:LiveCaptionEntries = @()
    $script:LiveCaptionCacheSignature = ''
    $LiveCaptionBorder.Visibility = [Windows.Visibility]::Collapsed
    $CaptionStatusText.Text = 'Captions will be generated on this computer from this voiceover.'
    Update-Estimate
    Invalidate-Preview $true
    Update-WorkflowState
})
$WatermarkText.Add_TextChanged({ Invalidate-Preview $false; Update-WorkflowState })
$OutputText.Add_TextChanged({ Update-WorkflowState })
$MinimumDurationText.Add_TextChanged({ Invalidate-Preview $true; Update-WorkflowState })
$MaximumDurationText.Add_TextChanged({ Invalidate-Preview $true; Update-WorkflowState })
$ZoomText.Add_TextChanged({ Invalidate-Preview $false; Update-WorkflowState })
$CrossfadeCheckBox.Add_Checked({ $CrossfadeDurationRow.IsEnabled = $true; Invalidate-Preview $false; Update-WorkflowState })
$CrossfadeCheckBox.Add_Unchecked({ $CrossfadeDurationRow.IsEnabled = $false; Invalidate-Preview $false; Update-WorkflowState })
$CrossfadeSecondsText.Add_TextChanged({ Invalidate-Preview $false; Update-WorkflowState })
$MotionQualityCombo.Add_SelectionChanged({ Invalidate-Preview $false; Update-WorkflowState })
$BlurSlider.Add_ValueChanged({ Update-SettingLabels; Invalidate-Preview $false; Update-WorkflowState })
$BrightnessSlider.Add_ValueChanged({ Update-SettingLabels; Invalidate-Preview $false; Update-WorkflowState })
$QualityCombo.Add_SelectionChanged({ Update-Estimate; Invalidate-Preview $false; Update-WorkflowState })
$CaptionModeCombo.Add_SelectionChanged({
    Update-LiveCaptionText
    Update-CaptionModeButtons
    Update-WorkflowState
})
$CaptionPresetCombo.Add_SelectionChanged({
    Update-CaptionPresetDescription
    Update-CaptionPresetSwatches
    if (-not $script:IsLoading -and -not $script:IsApplyingCaptionPreset) {
        Apply-CaptionPresetToControls (Get-ComboText $CaptionPresetCombo)
        $StatusText.Text = 'Caption preset applied instantly to the preview.'
    }
    Update-WorkflowState
})
$CaptionTabTypeButton.Add_Click({ Set-CaptionTab 'Type' })
$CaptionTabColourButton.Add_Click({ Set-CaptionTab 'Colour' })
$CaptionTabPositionButton.Add_Click({ Set-CaptionTab 'Position' })

$captionStyleChanged = {
    if (-not $script:IsLoading -and -not $script:IsApplyingCaptionPreset) {
        Apply-LiveCaptionStyle
        $StatusText.Text = 'Caption style updated live. No preview regeneration is needed.'
    }
}
$CaptionFontCombo.Add_SelectionChanged($captionStyleChanged)
$CaptionBoldCheckBox.Add_Click($captionStyleChanged)
$CaptionSizeSlider.Add_ValueChanged($captionStyleChanged)
$CaptionOutlineSlider.Add_ValueChanged($captionStyleChanged)
$CaptionShadowSlider.Add_ValueChanged($captionStyleChanged)
$CaptionBackgroundOpacitySlider.Add_ValueChanged($captionStyleChanged)
$CaptionAlignmentCombo.Add_SelectionChanged($captionStyleChanged)
$CaptionPositionXSlider.Add_ValueChanged($captionStyleChanged)
$CaptionPositionYSlider.Add_ValueChanged($captionStyleChanged)
$CaptionMaxWidthSlider.Add_ValueChanged($captionStyleChanged)
$CaptionWordsPerLineSlider.Add_ValueChanged({
    Update-CaptionControlLabels
    Update-LiveCaptionText
    if (-not $script:IsLoading -and -not $script:IsApplyingCaptionPreset) {
        $StatusText.Text = 'Caption words per line updated live.'
    }
})
$CaptionLineSpacingSlider.Add_ValueChanged($captionStyleChanged)
$CaptionTextColorText.Add_TextChanged($captionStyleChanged)
$CaptionOutlineColorText.Add_TextChanged($captionStyleChanged)
$CaptionBackgroundColorText.Add_TextChanged($captionStyleChanged)
$CaptionTextColorButton.Add_Click({ Show-CaptionColorPicker $CaptionTextColorText })
$CaptionOutlineColorButton.Add_Click({ Show-CaptionColorPicker $CaptionOutlineColorText })
$CaptionBackgroundColorButton.Add_Click({ Show-CaptionColorPicker $CaptionBackgroundColorText })

$CaptionMoveThumb.Add_DragDelta({
    param($sender, $eventArgs)
    $video = Get-LiveCaptionVideoRect
    if ($null -eq $video -or $video.Width -le 0 -or $video.Height -le 0) { return }
    $CaptionPositionXSlider.Value = [Math]::Max(5.0, [Math]::Min(95.0,
            [double]$CaptionPositionXSlider.Value + (100.0 * $eventArgs.HorizontalChange / $video.Width)))
    $CaptionPositionYSlider.Value = [Math]::Max(5.0, [Math]::Min(95.0,
            [double]$CaptionPositionYSlider.Value + (100.0 * $eventArgs.VerticalChange / $video.Height)))
    Apply-LiveCaptionStyle
})
$CaptionResizeThumb.Add_DragDelta({
    param($sender, $eventArgs)
    $change = ([double]$eventArgs.HorizontalChange + [double]$eventArgs.VerticalChange) / 8.0
    $CaptionSizeSlider.Value = [Math]::Max($CaptionSizeSlider.Minimum,
        [Math]::Min($CaptionSizeSlider.Maximum, [double]$CaptionSizeSlider.Value + $change))
    Apply-LiveCaptionStyle
})
$LiveCaptionBorder.Add_MouseWheel({
    param($sender, $eventArgs)
    $step = if ($eventArgs.Delta -gt 0) { 0.5 } else { -0.5 }
    $CaptionSizeSlider.Value = [Math]::Max($CaptionSizeSlider.Minimum,
        [Math]::Min($CaptionSizeSlider.Maximum, [double]$CaptionSizeSlider.Value + $step))
    $eventArgs.Handled = $true
})
$CaptionOverlayCanvas.Add_SizeChanged({ Update-LiveCaptionLayout })

$PreviewButton.Add_Click({ Start-VideoRender 'Preview' })
$FinalButton.Add_Click({ Start-VideoRender 'Final' })
$GenerateCaptionsButton.Add_Click({ [void](Start-CaptionGeneration -Force $true) })
$EditCaptionsButton.Add_Click({ Show-CaptionEditor })
$NavMediaButton.Add_Click({ Set-ActiveSection 'Media' })
$NavMotionButton.Add_Click({ Set-ActiveSection 'Motion' })
$NavCaptionsButton.Add_Click({ Set-ActiveSection 'Captions' })
$NavBlankingButton.Add_Click({ Set-ActiveSection 'Blanking' })
$NavExportButton.Add_Click({ Set-ActiveSection 'Export' })
Set-ActiveSection 'Media'
Build-CaptionModeButtons
Build-CaptionPresetSwatches
Set-CaptionTab 'Type'
$CancelButton.Add_Click({
    if ($null -ne $script:RenderProcess -and -not $script:RenderProcess.HasExited) {
        $script:CancelRequested = $true
        $StatusText.Text = 'Cancelling render...'
        Stop-RenderProcessTree
    }
})
$OpenFolderButton.Add_Click({
    if ($script:FinalOutputPath -and (Test-Path -LiteralPath $script:FinalOutputPath -PathType Leaf)) {
        Start-Process explorer.exe -ArgumentList "/select,`"$script:FinalOutputPath`""
    }
})
$SaveProjectButton.Add_Click({ Save-Project })
$OpenProjectButton.Add_Click({ Open-Project })
$RenderHistoryButton.Add_Click({ Show-RenderHistory })

# --- Batch and Single video ---------------------------------------------------

$ModeBatchButton.Add_Click({ Set-AppMode 'Batch' })
$ModeSingleButton.Add_Click({ Set-AppMode 'Single' })
$ScanChannelsButton.Add_Click({ Invoke-ChannelScan })
$EmptyScanButton.Add_Click({ Invoke-ChannelScan })
$AddVideoButton.Add_Click({ Add-QueueVideoByHand })
$EmptyAddButton.Add_Click({ Add-QueueVideoByHand })
$SavedProjectsButton.Add_Click({ Start-BatchRender })
$ClearFinishedButton.Add_Click({ Clear-FinishedQueueRows })
$ShowQueueButton.Add_Click({ Close-BatchRun })
$ScanSkippedButton.Add_Click({ Show-ScanSkipped })
$RenderAllButton.Add_Click({ Start-QueueRender })
$BatchPauseButton.Add_Click({
    if ($null -ne $script:RenderProcess -and -not $script:RenderProcess.HasExited) {
        $script:CancelRequested = $true
        $BatchPauseButton.IsEnabled = $false
        $StatusText.Text = 'Pausing the batch...'
        Stop-RenderProcessTree
    }
})
$BatchResumeButton.Add_Click({
    $run = $script:BatchRun
    if ($null -eq $run -or [bool]$run.Running) { return }
    Start-BatchRender -ProjectPaths @($run.ProjectPaths) -HistoryId ([string]$run.HistoryId)
})
$BatchOpenFolderButton.Add_Click({ Open-OutputInFolder -Path ([string]$script:FinalOutputPath) })
$BrowseBatchWatermarkButton.Add_Click({
    $selected = Select-OpenFile -Title 'Select watermark video' -Filter 'Video files (*.mov;*.mp4)|*.mov;*.mp4' -InitialPath $BatchWatermarkText.Text
    if ($selected) { $BatchWatermarkText.Text = $selected }
})
$BatchNavMotionButton.Add_Click({ Show-BatchSettings 'Motion' })
$BatchNavCaptionsButton.Add_Click({ Show-BatchSettings 'Captions' })
$BatchNavBlankingButton.Add_Click({ Show-BatchSettings 'Blanking' })
$BatchNavExportButton.Add_Click({ Show-BatchSettings 'Export' })
$SettingsBackButton.Add_Click({ Hide-BatchSettings })

$SelectedPreviewButton.Add_Click({ Start-QueueRowPreview -Id $script:SelectedQueueRowId })
$SelectedCaptionsButton.Add_Click({ Edit-QueueRowCaptions -Id $script:SelectedQueueRowId })
$SelectedRemoveButton.Add_Click({ Remove-QueueRow -Id $script:SelectedQueueRowId })
$SelectedNameText.Add_TextChanged({
    if ($script:IsFillingInspector) { return }
    $row = Get-SelectedQueueRow
    # The table's box carries the name; changing it there updates everything else.
    if ($null -ne $row -and $null -ne $row.Visual -and $row.Visual.NameBox.Text -ne $SelectedNameText.Text) { $row.Visual.NameBox.Text = $SelectedNameText.Text }
})
$SelectedOutputFolderText.Add_TextChanged({ Set-SelectedQueueRowPath -Field 'OutputFolder' -Value $SelectedOutputFolderText.Text })
$SelectedImagesText.Add_TextChanged({ Set-SelectedQueueRowPath -Field 'ImageFolder' -Value $SelectedImagesText.Text })
$SelectedAudioText.Add_TextChanged({ Set-SelectedQueueRowPath -Field 'AudioPath' -Value $SelectedAudioText.Text })
$SelectedWatermarkText.Add_TextChanged({ Set-SelectedQueueRowPath -Field 'WatermarkPath' -Value $SelectedWatermarkText.Text })
$SelectedOutputBrowseButton.Add_Click({
    $selected = Select-Folder -Description 'Select the folder this video is saved in' -InitialPath $SelectedOutputFolderText.Text
    if ($selected) { $SelectedOutputFolderText.Text = $selected; Save-QueueState }
})
$SelectedImagesBrowseButton.Add_Click({
    $selected = Select-Folder -Description 'Select this video''s images folder' -InitialPath $SelectedImagesText.Text
    if ($selected) { $SelectedImagesText.Text = $selected; Save-QueueState }
})
$SelectedAudioBrowseButton.Add_Click({
    $selected = Select-OpenFile -Title 'Select voiceover' -Filter $script:VoiceoverFilter -InitialPath $SelectedAudioText.Text
    if ($selected) { $SelectedAudioText.Text = $selected; Save-QueueState }
})
$SelectedWatermarkBrowseButton.Add_Click({
    $selected = Select-OpenFile -Title 'Select watermark video' -Filter 'Video files (*.mov;*.mp4)|*.mov;*.mp4' -InitialPath $SelectedWatermarkText.Text
    if ($selected) { $SelectedWatermarkText.Text = $selected; Save-QueueState }
})

$BackToQueueButton.Add_Click({
    $rowId = $script:QueuePreviewRowId
    Set-AppMode 'Batch'
    if (-not [string]::IsNullOrWhiteSpace($rowId) -and $null -eq $script:BatchRun) { Select-QueueRow -Id $rowId }
})
$EmptyPreviewButton.Add_Click({ Start-VideoRender 'Preview' })
# The tiles stand in for the Source section until there is a preview, so
# their Browse buttons are that section's own.
$SingleTileImagesButton.Add_Click({ $BrowseImagesButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent)) })
$SingleTileAudioButton.Add_Click({ $BrowseAudioButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent)) })
$SingleTileWatermarkButton.Add_Click({ $BrowseWatermarkButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent)) })
# Captions shown as "on" or "off" for the whole batch follow the mode.
$CaptionModeCombo.Add_SelectionChanged({ if ($script:AppMode -eq 'Batch') { Update-BatchInspector } })
$QualityCombo.Add_SelectionChanged({ Update-BatchFooter })
$MotionQualityCombo.Add_SelectionChanged({ Update-BatchFooter })

# Thumbnails of the queued videos and the lengths of their voiceovers arrive a
# little at a time, so a long queue never holds up the window.
$script:QueueTimer = [Windows.Threading.DispatcherTimer]::new()
$script:QueueTimer.Interval = [TimeSpan]::FromMilliseconds(60)
$script:QueueTimer.Add_Tick({
    try {
        if ($script:ThumbnailRequests.Count -gt 0) {
            $row = Get-QueueRow -Id ($script:ThumbnailRequests.Dequeue())
            if ($null -ne $row) { Update-QueueRowThumbnail -Row $row }
        }
        if ($null -ne $script:DurationProbe) { Complete-QueueDurationProbe }
        if ($script:ThumbnailRequests.Count -eq 0 -and $null -eq $script:DurationProbe) { $script:QueueTimer.Stop() }
    }
    catch {
        $script:QueueTimer.Stop()
        Write-ToolDiagnostic 'Queue thumbnail or voiceover measurement failed.' $_.Exception
    }
})

$PlayPauseButton.Add_Click({
    if ($null -eq $PreviewMedia.Source) { return }
    if ($PlayPauseButton.Content -eq 'Play') {
        $PreviewMedia.Play()
        $PlayPauseButton.Content = 'Pause'
    }
    else {
        $PreviewMedia.Pause()
        $PlayPauseButton.Content = 'Play'
    }
})
$SeekSlider.Add_ValueChanged({
    if ($null -ne $PreviewMedia.Source -and
        [Windows.Input.Mouse]::LeftButton -eq [Windows.Input.MouseButtonState]::Pressed) {
        $PreviewMedia.Position = [TimeSpan]::FromSeconds($SeekSlider.Value)
        Update-LiveCaptionText
    }
})
$VolumeSlider.Add_ValueChanged({ $PreviewMedia.Volume = $VolumeSlider.Value })
$FullScreenButton.Add_Click({ Toggle-FullScreen })
$PreviewMedia.Add_MediaEnded({
    $PreviewMedia.Position = [TimeSpan]::Zero
    $PreviewMedia.Pause()
    $PlayPauseButton.Content = 'Play'
    Update-LiveCaptionText
})
$PreviewMedia.Add_MediaFailed({
    $PlayPauseButton.Content = 'Play'
    $StatusText.Text = 'Windows could not play the preview inside the tool.'
})

$window.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [Windows.Input.Key]::Escape -and $script:IsFullScreen) {
        Toggle-FullScreen
    }
})

$window.Add_Closing({
    param($sender, $eventArgs)
    if ($null -ne $script:RenderProcess -and -not $script:RenderProcess.HasExited) {
        $choice = [System.Windows.MessageBox]::Show(
            $window,
            'A render is still running. Cancel it and close the tool?',
            'Render in progress',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($choice -ne [System.Windows.MessageBoxResult]::Yes) {
            $eventArgs.Cancel = $true
            return
        }
        $script:CancelRequested = $true
        Stop-RenderProcessTree
        if ($null -ne $script:RenderState) {
            Remove-RenderArtifacts -State $script:RenderState
        }
    }
    Save-UserSettings
    Save-QueueState
    Stop-PreviewPlayback
})

$window.Dispatcher.Add_UnhandledException({
    param($sender, $eventArgs)
    try {
        Write-ToolDiagnostic 'Unhandled WPF dispatcher exception.' $eventArgs.Exception
        $eventArgs.Handled = $true
        Show-ErrorMessage "The interface encountered an error and recovered instead of closing:`r`n`r`n$($eventArgs.Exception.Message)`r`n`r`nDiagnostic log:`r`n$script:DiagnosticLogPath"
    }
    catch {
        # Avoid a secondary exception inside the last-resort handler.
    }
})

Load-UserSettings
Load-RenderHistory
Update-SettingLabels
Update-CaptionPresetDescription
Update-CaptionControlLabels
Apply-LiveCaptionStyle
$script:AppVersion = Get-AppVersion -AppRoot $script:AppRoot
# Deliberately ASCII. This file has no byte order mark, so Windows PowerShell 5
# reads it in the system code page: a middot here arrived on screen as "Â·".
$AppSubtitleText.Text = "Slideshow automation studio  -  v$($script:AppVersion)"
Set-WindowIcon -Target $window
$appLogo = Get-AppIconImage
if ($null -ne $appLogo) { $AppLogoImage.Source = $appLogo }
# Also in the title bar and taskbar, so the running version is identifiable
# without opening anything.
$window.Title = "CreatorFlow $($script:AppVersion)"
$script:UpdateCheckState = $null
$script:UpdateTimer = $null
$script:PendingUpdate = $null

function Test-RenderBusy {
    # A render or caption job owns the FFmpeg processes and the output file, so
    # nothing may replace the application while one is running.
    return ($null -ne $script:RenderProcess -and -not $script:RenderProcess.HasExited)
}

function Show-UpdatePrompt {
    param([Parameter(Mandatory = $true)][psobject]$Update)

    $notes = [string]$Update.Notes
    if ([string]::IsNullOrWhiteSpace($notes)) { $notes = 'No release notes were published for this version.' }
    $message = @"
CreatorFlow $($Update.Version) is available. You have $($script:AppVersion).

$notes

Install it now? The tool will close, update, and reopen. Any render in progress will be interrupted.
"@
    $answer = [Windows.MessageBox]::Show($message, 'Update available', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }

    if (Test-RenderBusy) {
        Show-InfoMessage 'Finish or cancel the render that is running before installing an update.' 'Update'
        return
    }

    try {
        $StatusText.Text = "Downloading CreatorFlow $($Update.Version)..."
        $window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
        $staging = Join-Path $script:DataRoot 'update-staging'
        $archive = Save-UpdatePackage -Update $Update -StagingDirectory $staging
        $StatusText.Text = 'Installing update...'
        $window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
        Start-UpdateInstall -AppRoot $script:AppRoot -ArchivePath $archive -Version $Update.Version
        $window.Close()
    }
    catch {
        $StatusText.Text = 'The update was not installed.'
        Show-ErrorMessage "The update could not be installed.`r`n`r`n$($_.Exception.Message)"
    }
}

function Start-UpdateCheck {
    param([bool]$Announce = $false)

    if (-not (Test-UpdateConfigured)) {
        if ($Announce) {
            Show-InfoMessage 'This copy is not linked to a release feed yet, so it cannot check for updates. Set the GitHub account in SlideshowUpdate.psm1.' 'Check for Updates'
        }
        return
    }
    if ($null -ne $script:UpdateCheckState) { return }

    if ($Announce) { $StatusText.Text = 'Checking for updates...' }

    # Run the check on its own runspace. A slow or unreachable network must
    # never hold up the window, which is what a synchronous request would do.
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('ModulePath', (Join-Path $script:AppRoot 'SlideshowUpdate.psm1'))
    $runspace.SessionStateProxy.SetVariable('CurrentVersion', $script:AppVersion)
    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    [void]$shell.AddScript({
        Import-Module $ModulePath -Force
        Get-AvailableUpdate -CurrentVersion $CurrentVersion
    })

    $script:UpdateCheckState = [pscustomobject]@{
        Shell = $shell
        Runspace = $runspace
        Handle = $shell.BeginInvoke()
        Announce = $Announce
    }

    if ($null -eq $script:UpdateTimer) {
        $script:UpdateTimer = [Windows.Threading.DispatcherTimer]::new()
        $script:UpdateTimer.Interval = [TimeSpan]::FromMilliseconds(400)
        $script:UpdateTimer.Add_Tick({
            $state = $script:UpdateCheckState
            if ($null -eq $state -or -not $state.Handle.IsCompleted) { return }
            $script:UpdateTimer.Stop()
            $script:UpdateCheckState = $null

            $result = $null
            try { $result = $state.Shell.EndInvoke($state.Handle) | Select-Object -First 1 }
            catch { $result = $null }
            finally {
                $state.Shell.Dispose()
                $state.Runspace.Close()
                $state.Runspace.Dispose()
            }

            if ($null -ne $result) {
                $script:PendingUpdate = $result
                if (Test-RenderBusy) {
                    $StatusText.Text = "CreatorFlow $($result.Version) is available. Install it once this render finishes."
                }
                else { Show-UpdatePrompt -Update $result }
            }
            elseif ($state.Announce) {
                $StatusText.Text = "CreatorFlow $($script:AppVersion) is the newest version."
                Show-InfoMessage "You are running the newest version, $($script:AppVersion)." 'Check for Updates'
            }
        })
    }
    $script:UpdateTimer.Start()
}

$CheckUpdatesButton.Add_Click({ Start-UpdateCheck -Announce $true })

$script:FfmpegMissingAtLaunch = -not (Find-FFmpegTools)
$window.Add_ContentRendered({
    # Checked in the background once the window is on screen, so a slow network
    # delays nothing the person is waiting for.
    Start-UpdateCheck -Announce $false
    if ($script:FfmpegMissingAtLaunch) {
        $script:FfmpegMissingAtLaunch = $false
        Show-InfoMessage @'
FFmpeg is required before previewing or rendering.

Open PowerShell and run:

winget install --exact --id Gyan.FFmpeg --accept-package-agreements --accept-source-agreements

After installation, close and reopen this tool.
'@ 'Install FFmpeg'
    }
})
$script:IsLoading = $false
# The queue as it was left, and the window opens on it: most days are a batch.
Import-QueueState
Set-AppMode 'Batch'
if ($script:QueueRows.Count -gt 0) { Select-QueueRow -Id ([string]$script:QueueRows[0].Id) }
# The rail and the footer describe whatever was restored from the last session,
# so the window opens already telling the truth about where the work stands.
Update-WorkflowState

$window.ShowDialog() | Out-Null
