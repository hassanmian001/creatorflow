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
'@

$script:DataRoot = Join-Path $env:LOCALAPPDATA 'SlideshowVideoTool'
# Bumping this invalidates resume directories. Segments rendered by an older
# pipeline must not be concatenated with segments from a newer one, because the
# camera motion would visibly change partway through the video.
$script:RenderPipelineVersion = 'nvenc-opencl-v10-linear-zoom-pan-drift'
$script:SettingsPath = Join-Path $script:DataRoot 'settings.json'
$script:PreviewPath = Join-Path $script:DataRoot 'preview.mp4'
$script:LastErrorPath = Join-Path $script:DataRoot 'last-error.log'
$script:DiagnosticLogPath = Join-Path $script:DataRoot 'tool-diagnostic.log'
New-Item -ItemType Directory -Path $script:DataRoot -Force | Out-Null

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="CreatorFlow" Width="1280" Height="780" MinWidth="1000" MinHeight="650" WindowState="Maximized"
        WindowStartupLocation="CenterScreen" Background="#080B12" Foreground="#F7F7FB"
        FontFamily="Segoe UI" UseLayoutRounding="True">
    <Window.Resources>
        <SolidColorBrush x:Key="PanelBrush" Color="#111722"/>
        <SolidColorBrush x:Key="CardBrush" Color="#171E2B"/>
        <SolidColorBrush x:Key="BorderBrush" Color="#293246"/>
        <SolidColorBrush x:Key="MutedBrush" Color="#94A0B5"/>
        <SolidColorBrush x:Key="AccentBrush" Color="#8B5CF6"/>
        <SolidColorBrush x:Key="CyanBrush" Color="#22C7E8"/>

        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="#F7F7FB"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#20293A"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="#344057"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="13,8"/>
            <Setter Property="Margin" Value="3"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="7" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.86"/></Trigger>
                            <Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.68"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.38"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="NavButtonStyle" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="Padding" Value="16,12"/>
            <Setter Property="Margin" Value="8,3"/>
            <Setter Property="FontSize" Value="14"/>
        </Style>
        <Style x:Key="PrimaryButtonStyle" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="#7C3AED"/>
            <Setter Property="BorderBrush" Value="#9B70F7"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>
        <Style x:Key="CyanButtonStyle" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="#126D88"/>
            <Setter Property="BorderBrush" Value="#22C7E8"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#0E1420"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="#344057"/>
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="Margin" Value="3"/>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="#0E1420"/>
            <Setter Property="Foreground" Value="#111827"/>
            <Setter Property="BorderBrush" Value="#344057"/>
            <Setter Property="Padding" Value="7,5"/>
            <Setter Property="Margin" Value="3"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="#E9EAF0"/>
            <Setter Property="Margin" Value="4,6"/>
        </Style>
        <Style TargetType="Slider">
            <Setter Property="Margin" Value="4,3"/>
        </Style>
    </Window.Resources>

    <Grid x:Name="RootGrid">
        <Grid.RowDefinitions>
            <RowDefinition Height="58"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="72"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
            <ColumnDefinition x:Name="NavigationColumn" Width="175"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition x:Name="SettingsColumn" Width="340"/>
        </Grid.ColumnDefinitions>

        <Border Grid.Row="0" Grid.ColumnSpan="3" Background="#0B1019" BorderBrush="#252D3D" BorderThickness="0,0,0,1">
            <Grid Margin="18,0">
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <Border Width="36" Height="36" CornerRadius="10" Background="#7C3AED" Margin="0,0,11,0">
                        <TextBlock Text="C" FontWeight="Bold" FontSize="20" HorizontalAlignment="Center"/>
                    </Border>
                    <StackPanel>
                        <TextBlock Text="CreatorFlow" FontSize="20" FontWeight="SemiBold"/>
                        <TextBlock x:Name="AppSubtitleText" Text="Slideshow automation studio" Foreground="#7F8BA0" FontSize="11"/>
                    </StackPanel>
                </StackPanel>
                <TextBlock Grid.Column="1" Text="YouTube Slideshow Project" Foreground="#B8C0D0" FontSize="14" Margin="30,0"/>
                <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                    <Border Background="#121A20" BorderBrush="#315D4A" BorderThickness="1" CornerRadius="7" Padding="11,7" Margin="3">
                        <StackPanel Orientation="Horizontal">
                            <Ellipse Width="8" Height="8" Fill="#55D98B" Margin="0,0,7,0"/>
                            <TextBlock x:Name="EncoderText" Text="Checking GPU..." Foreground="#BDEFD0" FontSize="12"/>
                        </StackPanel>
                    </Border>
                    <Button x:Name="OpenProjectButton" Content="Open"/>
                    <Button x:Name="SaveProjectButton" Content="Save"/>
                </StackPanel>
            </Grid>
        </Border>

        <Border x:Name="NavigationPanel" Grid.Row="1" Grid.Column="0" Background="#0B1019" BorderBrush="#252D3D" BorderThickness="0,0,1,0">
            <Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <TextBlock Text="SETTINGS" Foreground="#667085" FontSize="10" FontWeight="Bold" Margin="20,20,0,8"/>
                <StackPanel Grid.Row="1">
                    <Button x:Name="NavMediaButton" Style="{StaticResource NavButtonStyle}" Content="Media and Audio"/>
                    <Button x:Name="NavMotionButton" Style="{StaticResource NavButtonStyle}" Content="Motion"/>
                    <Button x:Name="NavCaptionsButton" Style="{StaticResource NavButtonStyle}" Content="Captions"/>
                    <Button x:Name="NavBlankingButton" Style="{StaticResource NavButtonStyle}" Content="Blanking Fill"/>
                    <Button x:Name="NavExportButton" Style="{StaticResource NavButtonStyle}" Content="Export"/>
                    <Border Height="1" Background="#252D3D" Margin="15,15"/>
                    <Button x:Name="BatchButton" Style="{StaticResource NavButtonStyle}" Content="Batch Projects"/>
                    <Button x:Name="RenderHistoryButton" Style="{StaticResource NavButtonStyle}" Content="Render History"/>
                    <Button x:Name="CheckUpdatesButton" Style="{StaticResource NavButtonStyle}" Content="Check for Updates"/>
                </StackPanel>
                <StackPanel Grid.Row="2" Margin="8,0,8,12">
                    <Border Background="#111927" CornerRadius="8" Padding="12" Margin="3">
                        <StackPanel>
                            <TextBlock Text="1080p / 24 FPS" FontWeight="SemiBold"/>
                            <TextBlock Text="H.264 production workflow" Foreground="#78859A" FontSize="11" Margin="0,3,0,0"/>
                        </StackPanel>
                    </Border>
                </StackPanel>
            </Grid>
        </Border>

        <Grid x:Name="PlayerPanel" Grid.Row="1" Grid.Column="1" Margin="16,14,16,12">
            <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="145"/></Grid.RowDefinitions>
            <Border Grid.Row="0" Background="#020407" BorderBrush="#313A4D" BorderThickness="1" CornerRadius="10">
                <Grid ClipToBounds="True">
                    <MediaElement x:Name="PreviewMedia" LoadedBehavior="Manual" UnloadedBehavior="Stop" Stretch="Uniform" ScrubbingEnabled="True" Volume="0.8"/>
                    <Canvas x:Name="CaptionOverlayCanvas" Background="Transparent" ClipToBounds="True">
                        <Border x:Name="LiveCaptionBorder" Visibility="Collapsed" CornerRadius="7" Padding="12,7" Background="#00000000">
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
                                <Thumb x:Name="CaptionResizeThumb" Width="17" Height="17" HorizontalAlignment="Right" VerticalAlignment="Bottom" Cursor="SizeNWSE" Background="#CC22C7E8" BorderBrush="White" BorderThickness="1" ToolTip="Drag to resize captions">
                                    <Thumb.Template>
                                        <ControlTemplate TargetType="Thumb">
                                            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"/>
                                        </ControlTemplate>
                                    </Thumb.Template>
                                </Thumb>
                            </Grid>
                        </Border>
                    </Canvas>
                    <Border VerticalAlignment="Top" HorizontalAlignment="Right" Background="#B00B1019" CornerRadius="6" Padding="9,5" Margin="12">
                        <TextBlock Text="1920 x 1080   |   24 FPS" Foreground="#C7D0DF" FontSize="11"/>
                    </Border>
                    <Border VerticalAlignment="Bottom" Background="#D50A0D13" Padding="10,7">
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="120"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                            <Button x:Name="PlayPauseButton" Content="Play" Width="66"/>
                            <Slider x:Name="SeekSlider" Grid.Column="1" Minimum="0" Maximum="60" Margin="10,0"/>
                            <TextBlock x:Name="TimeText" Grid.Column="2" Text="00:00 / 01:00" Foreground="#C7D0DF" Margin="8,0"/>
                            <Slider x:Name="VolumeSlider" Grid.Column="3" Minimum="0" Maximum="1" Value="0.8" Margin="10,0"/>
                            <Button x:Name="FullScreenButton" Grid.Column="4" Content="Full Screen"/>
                        </Grid>
                    </Border>
                </Grid>
            </Border>

            <Border Grid.Row="1" Background="#101620" BorderBrush="#293246" BorderThickness="1" CornerRadius="10" Margin="0,12,0,0" Padding="12">
                <Grid>
                    <Grid.RowDefinitions><RowDefinition Height="30"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="Storyboard" FontSize="14" FontWeight="SemiBold"/>
                            <TextBlock x:Name="StoryboardSummaryText" Text="  Generate a preview to build the randomized timeline" Foreground="#78859A" FontSize="11" Margin="7,0,0,0"/>
                        </StackPanel>
                        <TextBlock Grid.Column="1" Text="Direct cuts  |  Random zoom" Foreground="#78859A" FontSize="11"/>
                    </Grid>
                    <ScrollViewer Grid.Row="1" HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Disabled">
                        <StackPanel x:Name="StoryboardPanel" Orientation="Horizontal"/>
                    </ScrollViewer>
                </Grid>
            </Border>
        </Grid>

        <Border x:Name="SettingsPanel" Grid.Row="1" Grid.Column="2" Background="#0E141F" BorderBrush="#252D3D" BorderThickness="1,0,0,0">
            <Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                <Border Grid.Row="0" Padding="15,13,15,12" BorderBrush="#252D3D" BorderThickness="0,0,0,1">
                    <StackPanel>
                        <TextBlock x:Name="SectionTitleText" Text="Media and Audio" FontSize="15" FontWeight="SemiBold"/>
                        <TextBlock x:Name="SectionHintText" Text="Pick the photographs, the voiceover, and the watermark clip." Foreground="#78859A" FontSize="10.5" TextWrapping="Wrap" Margin="0,3,0,0"/>
                    </StackPanel>
                </Border>

                <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                    <!-- Every section occupies the same cell; only the active one is visible. -->
                    <Grid Margin="13,13,13,20">

                        <StackPanel x:Name="SectionMedia">
                            <TextBlock Text="Image folder" Foreground="#94A0B5" FontSize="11"/>
                            <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBox x:Name="ImageFolderText"/><Button x:Name="BrowseImagesButton" Grid.Column="1" Content="Browse"/></Grid>
                            <TextBlock Text="Voiceover (M4A)" Foreground="#94A0B5" FontSize="11" Margin="0,9,0,0"/>
                            <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBox x:Name="AudioText"/><Button x:Name="BrowseAudioButton" Grid.Column="1" Content="Browse"/></Grid>
                            <TextBlock Text="Screen watermark (MOV or MP4)" Foreground="#94A0B5" FontSize="11" Margin="0,9,0,0"/>
                            <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBox x:Name="WatermarkText"/><Button x:Name="BrowseWatermarkButton" Grid.Column="1" Content="Browse"/></Grid>
                            <Border Background="#131C2A" CornerRadius="8" Padding="12" Margin="3,16,3,0">
                                <StackPanel>
                                    <TextBlock Text="Only files directly inside the folder are used." Foreground="#8490A5" FontSize="10.5" TextWrapping="Wrap"/>
                                    <TextBlock Text="JPG, JPEG, PNG and WEBP are supported." Foreground="#8490A5" FontSize="10.5" TextWrapping="Wrap" Margin="0,4,0,0"/>
                                </StackPanel>
                            </Border>
                        </StackPanel>

                        <StackPanel x:Name="SectionMotion" Visibility="Collapsed">
                            <Grid Margin="0,4"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="78"/></Grid.ColumnDefinitions><TextBlock Text="Minimum duration" Foreground="#B9C1D0"/><TextBox x:Name="MinimumDurationText" Grid.Column="1" Text="5.0" HorizontalContentAlignment="Center"/></Grid>
                            <Grid Margin="0,4"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="78"/></Grid.ColumnDefinitions><TextBlock Text="Maximum duration" Foreground="#B9C1D0"/><TextBox x:Name="MaximumDurationText" Grid.Column="1" Text="7.0" HorizontalContentAlignment="Center"/></Grid>
                            <Grid Margin="0,4"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="78"/></Grid.ColumnDefinitions><TextBlock Text="Maximum zoom" Foreground="#B9C1D0"/><TextBox x:Name="ZoomText" Grid.Column="1" Text="110" HorizontalContentAlignment="Center"/></Grid>
                            <Border Background="#131C2A" CornerRadius="8" Padding="12" Margin="3,16,3,0">
                                <StackPanel>
                                    <TextBlock Text="Each image holds for a random time inside this range." Foreground="#8490A5" FontSize="10.5" TextWrapping="Wrap"/>
                                    <TextBlock Text="It also zooms in or out and drifts slowly across one axis. Both move at a constant rate, so the motion never stalls before a cut." Foreground="#8490A5" FontSize="10.5" TextWrapping="Wrap" Margin="0,5,0,0"/>
                                </StackPanel>
                            </Border>
                        </StackPanel>

                        <StackPanel x:Name="SectionCaptions" Visibility="Collapsed">
                            <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="Mode" Foreground="#B9C1D0"/><ComboBox x:Name="CaptionModeCombo" Grid.Column="1" SelectedIndex="1"><ComboBoxItem Content="Off"/><ComboBoxItem Content="SRT only"/><ComboBoxItem Content="Burned only"/><ComboBoxItem Content="Burned + SRT"/></ComboBox></Grid>
                            <Grid Margin="0,4,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="Preset" Foreground="#B9C1D0"/><ComboBox x:Name="CaptionPresetCombo" Grid.Column="1" SelectedIndex="0"><ComboBoxItem Content="1. Clean YouTube"/><ComboBoxItem Content="2. Modern News"/><ComboBoxItem Content="3. Minimal Shadow"/><ComboBoxItem Content="4. Translucent Box"/><ComboBoxItem Content="5. Yellow Headline"/><ComboBoxItem Content="6. Cyan Accent"/><ComboBoxItem Content="7. Documentary Serif"/><ComboBoxItem Content="8. Yellow Emphasis"/><ComboBoxItem Content="9. Upper Safe"/><ComboBoxItem Content="10. Compact Broadcast"/></ComboBox></Grid>
                            <TextBlock x:Name="CaptionPresetHelpText" Text="White semibold text, centered safely above the bottom." Foreground="#8490A5" FontSize="10" TextWrapping="Wrap" Margin="99,4,4,2"/>
                            <Grid Margin="0,7,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                <Button x:Name="GenerateCaptionsButton" Content="Generate Captions" Background="#322257" BorderBrush="#7045C7"/>
                                <Button x:Name="EditCaptionsButton" Grid.Column="1" Content="Edit Captions" Background="#20293A" BorderBrush="#4C5A72"/>
                            </Grid>
                            <TextBlock x:Name="CaptionStatusText" Text="Select a voiceover; captions are generated locally." Foreground="#8490A5" FontSize="11" TextWrapping="Wrap" Margin="4,4"/>

                            <TextBlock Text="TYPE" Foreground="#738097" FontSize="9.5" FontWeight="Bold" Margin="4,14,0,6"/>
                            <Grid Margin="0,2"><Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="Font" Foreground="#B9C1D0"/><ComboBox x:Name="CaptionFontCombo" Grid.Column="1" SelectedIndex="0"><ComboBoxItem Content="Segoe UI Semibold"/><ComboBoxItem Content="Segoe UI"/><ComboBoxItem Content="Arial"/><ComboBoxItem Content="Arial Narrow"/><ComboBoxItem Content="Georgia"/><ComboBoxItem Content="Calibri"/><ComboBoxItem Content="Verdana"/><ComboBoxItem Content="Trebuchet MS"/></ComboBox></Grid>
                            <CheckBox x:Name="CaptionBoldCheckBox" Content="Bold text" IsChecked="True" Margin="99,2,0,3"/>
                            <Grid Margin="0,2"><Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/></Grid.ColumnDefinitions><TextBlock Text="Size" Foreground="#B9C1D0"/><Slider x:Name="CaptionSizeSlider" Grid.Column="1" Minimum="10" Maximum="36" Value="16" TickFrequency="1"/><TextBlock x:Name="CaptionSizeValueText" Grid.Column="2" Text="16" HorizontalAlignment="Right"/></Grid>
                            <Grid Margin="0,2"><Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/></Grid.ColumnDefinitions><TextBlock Text="Outline" Foreground="#B9C1D0"/><Slider x:Name="CaptionOutlineSlider" Grid.Column="1" Minimum="0" Maximum="8" Value="2" TickFrequency="0.5"/><TextBlock x:Name="CaptionOutlineValueText" Grid.Column="2" Text="2" HorizontalAlignment="Right"/></Grid>
                            <Grid Margin="0,2"><Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/></Grid.ColumnDefinitions><TextBlock Text="Shadow" Foreground="#B9C1D0"/><Slider x:Name="CaptionShadowSlider" Grid.Column="1" Minimum="0" Maximum="8" Value="0" TickFrequency="0.5"/><TextBlock x:Name="CaptionShadowValueText" Grid.Column="2" Text="0" HorizontalAlignment="Right"/></Grid>

                            <TextBlock Text="COLOUR" Foreground="#738097" FontSize="9.5" FontWeight="Bold" Margin="4,14,0,6"/>
                            <Grid Margin="0,2"><Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock Text="Text" Foreground="#B9C1D0"/><TextBox x:Name="CaptionTextColorText" Grid.Column="1" Text="#FFFFFF"/><Button x:Name="CaptionTextColorButton" Grid.Column="2" Content="Pick"/></Grid>
                            <Grid Margin="0,2"><Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock Text="Outline" Foreground="#B9C1D0"/><TextBox x:Name="CaptionOutlineColorText" Grid.Column="1" Text="#000000"/><Button x:Name="CaptionOutlineColorButton" Grid.Column="2" Content="Pick"/></Grid>
                            <Grid Margin="0,2"><Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock Text="Box" Foreground="#B9C1D0"/><TextBox x:Name="CaptionBackgroundColorText" Grid.Column="1" Text="#000000"/><Button x:Name="CaptionBackgroundColorButton" Grid.Column="2" Content="Pick"/></Grid>
                            <Grid Margin="0,2"><Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/></Grid.ColumnDefinitions><TextBlock Text="Box opacity" Foreground="#B9C1D0"/><Slider x:Name="CaptionBackgroundOpacitySlider" Grid.Column="1" Minimum="0" Maximum="100" Value="0" TickFrequency="5"/><TextBlock x:Name="CaptionBackgroundOpacityValueText" Grid.Column="2" Text="0%" HorizontalAlignment="Right"/></Grid>

                            <TextBlock Text="PLACEMENT" Foreground="#738097" FontSize="9.5" FontWeight="Bold" Margin="4,14,0,6"/>
                            <Grid Margin="0,2"><Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="Alignment" Foreground="#B9C1D0"/><ComboBox x:Name="CaptionAlignmentCombo" Grid.Column="1" SelectedIndex="1"><ComboBoxItem Content="Left"/><ComboBoxItem Content="Center"/><ComboBoxItem Content="Right"/></ComboBox></Grid>
                            <Grid Margin="0,2"><Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/></Grid.ColumnDefinitions><TextBlock Text="Position X" Foreground="#B9C1D0"/><Slider x:Name="CaptionPositionXSlider" Grid.Column="1" Minimum="5" Maximum="95" Value="50"/><TextBlock x:Name="CaptionPositionXValueText" Grid.Column="2" Text="50%" HorizontalAlignment="Right"/></Grid>
                            <Grid Margin="0,2"><Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/></Grid.ColumnDefinitions><TextBlock Text="Position Y" Foreground="#B9C1D0"/><Slider x:Name="CaptionPositionYSlider" Grid.Column="1" Minimum="5" Maximum="95" Value="70"/><TextBlock x:Name="CaptionPositionYValueText" Grid.Column="2" Text="70%" HorizontalAlignment="Right"/></Grid>
                            <Grid Margin="0,2"><Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/></Grid.ColumnDefinitions><TextBlock Text="Max width" Foreground="#B9C1D0"/><Slider x:Name="CaptionMaxWidthSlider" Grid.Column="1" Minimum="25" Maximum="95" Value="82"/><TextBlock x:Name="CaptionMaxWidthValueText" Grid.Column="2" Text="82%" HorizontalAlignment="Right"/></Grid>
                            <Grid Margin="0,2"><Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/></Grid.ColumnDefinitions><TextBlock Text="Words / line" Foreground="#B9C1D0"/><Slider x:Name="CaptionWordsPerLineSlider" Grid.Column="1" Minimum="3" Maximum="20" Value="8" TickFrequency="1" IsSnapToTickEnabled="True"/><TextBlock x:Name="CaptionWordsPerLineValueText" Grid.Column="2" Text="8" HorizontalAlignment="Right"/></Grid>
                            <Grid Margin="0,2"><Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/></Grid.ColumnDefinitions><TextBlock Text="Line height" Foreground="#B9C1D0"/><Slider x:Name="CaptionLineSpacingSlider" Grid.Column="1" Minimum="0.8" Maximum="1.5" Value="1" TickFrequency="0.05"/><TextBlock x:Name="CaptionLineSpacingValueText" Grid.Column="2" Text="1.00" HorizontalAlignment="Right"/></Grid>
                            <TextBlock Text="Drag the caption in the player to move it. Drag the cyan corner to resize it." Foreground="#22C7E8" FontSize="10" TextWrapping="Wrap" Margin="4,10,4,0"/>
                        </StackPanel>

                        <StackPanel x:Name="SectionBlanking" Visibility="Collapsed">
                            <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="48"/></Grid.ColumnDefinitions><TextBlock Text="Background blur" Foreground="#B9C1D0"/><TextBlock x:Name="BlurValueText" Grid.Column="1" Text="40" HorizontalAlignment="Right"/></Grid>
                            <Slider x:Name="BlurSlider" Minimum="0" Maximum="100" Value="40" TickFrequency="1" IsSnapToTickEnabled="True"/>
                            <Grid Margin="0,12,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="48"/></Grid.ColumnDefinitions><TextBlock Text="Background brightness" Foreground="#B9C1D0"/><TextBlock x:Name="BrightnessValueText" Grid.Column="1" Text="65%" HorizontalAlignment="Right"/></Grid>
                            <Slider x:Name="BrightnessSlider" Minimum="20" Maximum="100" Value="65" TickFrequency="1" IsSnapToTickEnabled="True"/>
                            <Border Background="#131C2A" CornerRadius="8" Padding="12" Margin="3,18,3,0">
                                <TextBlock Text="A photograph that does not fill the 16:9 frame is shown whole, over a blurred and darkened copy of itself. These two controls shape that backdrop." Foreground="#8490A5" FontSize="10.5" TextWrapping="Wrap"/>
                            </Border>
                        </StackPanel>

                        <StackPanel x:Name="SectionExport" Visibility="Collapsed">
                            <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="112"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="Quality mode" Foreground="#B9C1D0"/><ComboBox x:Name="QualityCombo" Grid.Column="1" SelectedIndex="3"><ComboBoxItem Content="Compact"/><ComboBoxItem Content="Balanced"/><ComboBoxItem Content="High"/><ComboBoxItem Content="YouTube"/></ComboBox></Grid>
                            <Grid Margin="0,6"><Grid.ColumnDefinitions><ColumnDefinition Width="112"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="Output format" Foreground="#B9C1D0"/><TextBlock Grid.Column="1" Text="1080p / H.264 / 24 FPS"/></Grid>
                            <Grid Margin="0,6"><Grid.ColumnDefinitions><ColumnDefinition Width="112"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="Estimated size" Foreground="#B9C1D0"/><TextBlock x:Name="EstimateText" Grid.Column="1" Text="Scan voiceover first" Foreground="#22C7E8"/></Grid>
                            <TextBlock Text="Final output" Foreground="#94A0B5" FontSize="11" Margin="0,10,0,0"/>
                            <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBox x:Name="OutputText"/><Button x:Name="BrowseOutputButton" Grid.Column="1" Content="Save As"/></Grid>
                        </StackPanel>

                    </Grid>
                </ScrollViewer>
            </Grid>
        </Border>

        <Border x:Name="StatusPanel" Grid.Row="2" Grid.ColumnSpan="3" Background="#0B1019" BorderBrush="#252D3D" BorderThickness="0,1,0,0">
            <Grid Margin="16,0">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel VerticalAlignment="Center" Margin="0,0,20,0">
                    <TextBlock x:Name="StatusText" Text="Ready to create" FontSize="14" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                    <ProgressBar x:Name="RenderProgress" Height="8" Minimum="0" Maximum="100" Value="0" Foreground="#8B5CF6" Background="#20293A" Margin="0,7,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <Button x:Name="PreviewButton" Content="60s Preview" Style="{StaticResource PrimaryButtonStyle}" MinWidth="118"/>
                    <Button x:Name="FinalButton" Content="Render Final" Style="{StaticResource CyanButtonStyle}" MinWidth="126" IsEnabled="False"/>
                    <Button x:Name="CancelButton" Content="Cancel" Background="#5C2430" BorderBrush="#9B4053" IsEnabled="False"/>
                    <Button x:Name="OpenFolderButton" Content="Open Folder" IsEnabled="False"/>
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
    'EncoderText', 'OpenProjectButton', 'SaveProjectButton', 'BatchButton', 'RenderHistoryButton',
    'CheckUpdatesButton', 'AppSubtitleText',
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
    'OpenFolderButton', 'RenderProgress'
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
    'Media'    = @{ Panel = $SectionMedia;    Button = $NavMediaButton;    Title = 'Media and Audio'; Hint = 'Pick the photographs, the voiceover, and the watermark clip.' }
    'Motion'   = @{ Panel = $SectionMotion;   Button = $NavMotionButton;   Title = 'Motion';          Hint = 'How long each image holds, and how far it zooms.' }
    'Captions' = @{ Panel = $SectionCaptions; Button = $NavCaptionsButton; Title = 'Captions';        Hint = 'Generated locally from the voiceover. Style updates the player instantly.' }
    'Blanking' = @{ Panel = $SectionBlanking; Button = $NavBlankingButton; Title = 'Blanking Fill';   Hint = 'The blurred backdrop behind images that do not fill the frame.' }
    'Export'   = @{ Panel = $SectionExport;   Button = $NavExportButton;   Title = 'Export';          Hint = 'Quality target and where the finished MP4 is written.' }
}
$script:ActiveSectionBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#251A43')
$script:ActiveSectionBorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#6D46BE')
$script:TransparentBrush = [Windows.Media.Brushes]::Transparent

function Set-ActiveSection {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not $script:SettingsSections.Contains($Name)) { return }
    foreach ($key in $script:SettingsSections.Keys) {
        $entry = $script:SettingsSections[$key]
        $isActive = ($key -eq $Name)
        $entry.Panel.Visibility = if ($isActive) { 'Visible' } else { 'Collapsed' }
        $entry.Button.Background = if ($isActive) { $script:ActiveSectionBrush } else { $script:TransparentBrush }
        $entry.Button.BorderBrush = if ($isActive) { $script:ActiveSectionBorderBrush } else { $script:TransparentBrush }
        $entry.Button.FontWeight = if ($isActive) { 'SemiBold' } else { 'Normal' }
    }
    $active = $script:SettingsSections[$Name]
    $SectionTitleText.Text = [string]$active.Title
    $SectionHintText.Text = [string]$active.Hint
    $script:ActiveSection = $Name
}

$script:IsLoading = $true
$script:FfmpegPath = $null
$script:FfprobePath = $null
$script:SelectedEncoder = $null
$script:RecommendedParallelSegments = $null
$script:VulkanDeviceIndex = $null
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
$script:LowResolutionWarningFolder = ''
$script:RenderHistoryPath = Join-Path $script:DataRoot 'render-history.json'
$script:RenderJobsRoot = Join-Path $script:DataRoot 'render-jobs'
$script:RenderHistory = @()
$script:IsFullScreen = $false
$script:OriginalWindowState = $window.WindowState
$script:OriginalWindowStyle = $window.WindowStyle
$script:OriginalSettingsWidth = $SettingsColumn.Width
$script:OriginalNavigationWidth = $NavigationColumn.Width

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
    foreach ($colorControl in @($CaptionTextColorText, $CaptionOutlineColorText, $CaptionBackgroundColorText)) {
        if ($colorControl.Text.Trim() -notmatch '^#[0-9A-Fa-f]{6}$') {
            throw 'Caption colors must use six-digit hex values such as #FFFFFF or #000000.'
        }
    }

    return [pscustomobject]@{
        MinimumDuration = $minimum
        MaximumDuration = $maximum
        ZoomMaximum = $zoom
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
    $arguments = @(
        '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'color=c=black:s=64x64:r=1',
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
    $fallbackIndex = $null
    foreach ($deviceIndex in @(1, 0, 2, 3)) {
        $arguments = @(
            '-hide_banner', '-loglevel', 'info',
            '-init_hw_device', "vulkan=slideshowgpu:$deviceIndex",
            '-filter_hw_device', 'slideshowgpu',
            '-f', 'lavfi', '-i', 'color=c=black:s=64x64:r=1',
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
    # A lane is mostly one saturated core running zoompan, which cannot be
    # threaded, plus part of a second for the threaded scale, blur and encode
    # around it. Budgeting four cores each was leaving most of a modern machine
    # idle for the entire render.
    $byCpu = [int][Math]::Floor($logicalCores / 2.0)

    # Assume a modest machine when the memory query is unavailable.
    $totalGb = 8.0
    try {
        $bytes = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
        if ($bytes -gt 0) { $totalGb = [double]$bytes / 1GB }
    }
    catch {}
    # Measured rather than estimated: one lane rendering a 30 second segment
    # peaked at just over 1.5 GB, and stayed there whether it was given two
    # filter threads or six. 1.6 covers that.
    #
    # The five gigabytes held back are for Windows, this tool, and whatever the
    # person is doing while they wait. Reserving less looked affordable on a
    # machine with nothing else running and would have put an eight gigabyte
    # laptop into swap, which costs far more than the extra lane wins.
    $byMemory = [int][Math]::Floor(($totalGb - 5.0) / 1.6)

    $lanes = [Math]::Min($byCpu, $byMemory)
    if ($lanes -lt 1) { $lanes = 1 }
    if ($lanes -gt 6) { $lanes = 6 }

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

    if ($skipped.Count -gt 0) {
        $names = ($skipped | ForEach-Object { [IO.Path]::GetFileName($_) }) -join "`r`n"
        Show-InfoMessage "These unreadable images will be skipped:`r`n`r`n$names" 'Skipped images'
    }
    if ($valid.Count -lt 2) {
        throw 'At least two readable images are required.'
    }
    if ($upscaled.Count -gt 0 -and -not [string]::Equals($script:LowResolutionWarningFolder, $Folder, [StringComparison]::OrdinalIgnoreCase)) {
        $examples = @($upscaled | Select-Object -First 8) -join "`r`n"
        $more = if ($upscaled.Count -gt 8) { "`r`n...and $($upscaled.Count - 8) more." } else { '' }
        Show-InfoMessage "$($upscaled.Count) image(s) are smaller than their fitted 1080p display size and must be enlarged. The renderer will use high-quality Lanczos scaling, but it cannot recreate detail missing from the originals. Use YouTube quality and source images of at least 1920x1080 when possible.`r`n`r`n$examples$more" 'Low-resolution images'
        $script:LowResolutionWarningFolder = $Folder
    }
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
    if ([string]::IsNullOrWhiteSpace($AudioPath)) { throw 'Select a valid M4A voiceover.' }
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

function Get-CurrentPreviewFingerprint {
    param([psobject]$Settings)
    $watermark = Get-Item -LiteralPath $WatermarkText.Text
    return @(
        $script:PlanSignature,
        $Settings.ZoomMaximum,
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
            -Fps 24
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
    $OpenProjectButton.IsEnabled = -not $Rendering
    $SaveProjectButton.IsEnabled = -not $Rendering
    $BatchButton.IsEnabled = -not $Rendering
    $GenerateCaptionsButton.IsEnabled = -not $Rendering
    $EditCaptionsButton.IsEnabled = -not $Rendering
    $CancelButton.IsEnabled = $Rendering
    if ($Rendering) {
        $FinalButton.IsEnabled = $false
        $OpenFolderButton.IsEnabled = $false
    }
    else {
        $FinalButton.IsEnabled = $script:PreviewValid
    }
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
    param([bool]$Force = $false)
    try {
        Assert-FFmpegAvailable
        $audioPath = $AudioText.Text.Trim()
        if (-not (Test-Path -LiteralPath $audioPath -PathType Leaf) -or [IO.Path]::GetExtension($audioPath).ToLowerInvariant() -ne '.m4a') {
            throw 'Select a valid M4A voiceover before generating captions.'
        }
        $outputSrt = Get-CaptionCachePath -AudioPath $audioPath -DataRoot $script:DataRoot
        if (-not $Force -and (Test-Path -LiteralPath $outputSrt -PathType Leaf)) {
            $script:CaptionPath = $outputSrt
            $script:LiveCaptionCacheSignature = ''
            Refresh-LiveCaptionEntries
            Update-LiveCaptionText
            $CaptionStatusText.Text = 'Automatic captions are ready.'
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
            DurationSeconds = 1.0
            Encoder = 'offline whisper.cpp'
        }
        $RenderProgress.Value = 0
        $StatusText.Text = 'Starting automatic caption generation...'
        $CaptionStatusText.Text = 'Preparing offline caption engine...'
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
    try {
        $renderTimer.Stop()
        $process.WaitForExit()
        $process.Refresh()
        if ($script:CancelRequested) {
            $StatusText.Text = 'Caption generation cancelled.'
            $CaptionStatusText.Text = 'Captions were not changed.'
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
        $script:CaptionPath = $state.OutputSrt
        $script:LiveCaptionCacheSignature = ''
        Refresh-LiveCaptionEntries
        Update-LiveCaptionText
        $RenderProgress.Value = 100
        $CaptionStatusText.Text = 'Automatic captions are ready.'
        $StatusText.Text = 'Automatic captions are ready and cached for this voiceover.'
        Write-ToolDiagnostic "Caption generation completed at $($state.OutputSrt)"
    }
    catch {
        Write-ToolDiagnostic 'Caption generation failed.' $_.Exception
        Show-ErrorMessage $_.Exception.Message 'Caption generation failed'
        $CaptionStatusText.Text = 'Caption generation failed; see the diagnostic log.'
        $pendingKind = $null
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
    try {
        $audioPath = $AudioText.Text.Trim()
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
        Background="#0B1019" Foreground="White" FontFamily="Segoe UI">
    <Window.Resources>
        <Style TargetType="TextBlock"><Setter Property="Foreground" Value="White"/></Style>
        <Style TargetType="Button"><Setter Property="Background" Value="#20293A"/><Setter Property="Foreground" Value="White"/><Setter Property="BorderBrush" Value="#3B4860"/><Setter Property="Padding" Value="12,7"/><Setter Property="Margin" Value="3"/></Style>
        <Style TargetType="TextBox"><Setter Property="Background" Value="#111827"/><Setter Property="Foreground" Value="White"/><Setter Property="BorderBrush" Value="#354158"/><Setter Property="Padding" Value="7"/><Setter Property="Margin" Value="3"/></Style>
        <!-- DataGrid's default row template uses a white alternate row.  Set
             every layer explicitly so white caption text stays readable. -->
        <Style TargetType="DataGridColumnHeader"><Setter Property="Background" Value="#1B2433"/><Setter Property="Foreground" Value="White"/><Setter Property="BorderBrush" Value="#354158"/><Setter Property="Padding" Value="8,7"/></Style>
        <Style TargetType="DataGridCell"><Setter Property="Background" Value="Transparent"/><Setter Property="Foreground" Value="White"/><Setter Property="BorderBrush" Value="#263043"/><Setter Property="VerticalContentAlignment" Value="Center"/><Setter Property="Padding" Value="7,3"/></Style>
        <Style TargetType="DataGridRow"><Setter Property="Background" Value="#0F1520"/><Setter Property="Foreground" Value="White"/><Setter Property="VerticalContentAlignment" Value="Center"/><Style.Triggers><Trigger Property="ItemsControl.AlternationIndex" Value="1"><Setter Property="Background" Value="#141B27"/></Trigger><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#30244F"/></Trigger></Style.Triggers></Style>
    </Window.Resources>
    <Grid Margin="14">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel><TextBlock Text="Caption Editor" FontSize="22" FontWeight="SemiBold"/><TextBlock Text="Changes appear live on the main player. You can use its Play, Pause, seek, style controls, and drag handles while this editor is open." Foreground="#8C98AD" Margin="0,4,0,10" TextWrapping="Wrap"/></StackPanel>
            <Button x:Name="PreviewCaptionButton" Grid.Column="1" Content="Play Selected Caption" VerticalAlignment="Top" Background="#34245B"/>
        </Grid>
        <Border Grid.Row="1" Background="#151C28" BorderBrush="#2C3649" BorderThickness="1" CornerRadius="7" Padding="8" Margin="0,0,0,10">
            <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBox x:Name="FindText" ToolTip="Text to find"/>
                <TextBox x:Name="ReplaceText" Grid.Column="1" ToolTip="Replacement text"/>
                <Button x:Name="ReplaceAllButton" Grid.Column="2" Content="Replace All"/>
                <Button x:Name="AddCaptionButton" Grid.Column="3" Content="Add Row"/>
                <Button x:Name="SplitCaptionButton" Grid.Column="4" Content="Split"/>
                <Button x:Name="MergeCaptionButton" Grid.Column="5" Content="Merge Next"/>
                <Button x:Name="DeleteCaptionButton" Grid.Column="6" Content="Delete" Background="#542735"/>
            </Grid>
        </Border>
        <DataGrid x:Name="CaptionGrid" Grid.Row="2" AutoGenerateColumns="False" CanUserAddRows="False" CanUserDeleteRows="False"
                  HeadersVisibility="Column" GridLinesVisibility="Horizontal" RowHeight="44" AlternationCount="2" Background="#0F1520" Foreground="White"
                  BorderBrush="#303A4D" HorizontalGridLinesBrush="#263043" AlternatingRowBackground="#141B27"
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
            <TextBlock x:Name="EditorStatus" Text="Ready" Foreground="#8C98AD"/>
            <StackPanel Grid.Column="1" Orientation="Horizontal"><Button x:Name="CancelEditorButton" Content="Cancel"/><Button x:Name="SaveEditorButton" Content="Save Captions" Background="#7C3AED" BorderBrush="#9B70F7" FontWeight="SemiBold"/></StackPanel>
        </Grid>
    </Grid>
</Window>
'@
        $reader = [Xml.XmlNodeReader]::new([xml]$editorXaml)
        $editor = [Windows.Markup.XamlReader]::Load($reader)
        $editor.Owner = $window
        $grid = $editor.FindName('CaptionGrid')
        $grid.ItemsSource = $entries
        $findText = $editor.FindName('FindText')
        $replaceText = $editor.FindName('ReplaceText')
        $editorStatus = $editor.FindName('EditorStatus')
        $script:CaptionEditorSaved = $false
        $script:CaptionEditorOpen = $true
        $script:LiveCaptionOverrideEntries = $entries
        $editorLiveTimer = [Windows.Threading.DispatcherTimer]::new()
        $editorLiveTimer.Interval = [TimeSpan]::FromMilliseconds(120)
        $editorLiveTimer.Add_Tick({
                $script:LiveCaptionOverrideEntries = $entries
                Update-LiveCaptionText
            })
        $editorLiveTimer.Start()

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
                    $split = $PreviewMedia.Position
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
                    if ($null -ne $PreviewMedia.Source) {
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
        $previousBatchEnabled = $BatchButton.IsEnabled
        $EditCaptionsButton.IsEnabled = $false
        $PreviewButton.IsEnabled = $false
        $FinalButton.IsEnabled = $false
        $GenerateCaptionsButton.IsEnabled = $false
        $BatchButton.IsEnabled = $false
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
        $BatchButton.IsEnabled = $previousBatchEnabled
        $script:LiveCaptionOverrideEntries = $null
        $script:LiveCaptionCacheSignature = ''
        Refresh-LiveCaptionEntries
        Update-LiveCaptionText
        if ($script:CaptionEditorSaved) {
            $script:CaptionPath = $captionPath
            $CaptionStatusText.Text = "Captions edited and saved ($($entries.Count) entries)."
            if ((Get-ComboText $CaptionModeCombo) -in @('SRT only', 'Burned + SRT') -and $script:FinalOutputPath -and (Test-Path -LiteralPath $script:FinalOutputPath -PathType Leaf)) {
                [void](Copy-SrtWithWordWrapping -SourcePath $captionPath -DestinationPath ([IO.Path]::ChangeExtension($script:FinalOutputPath, '.srt')) -MaxWordsPerLine ([int][Math]::Round($CaptionWordsPerLineSlider.Value)))
            }
            $StatusText.Text = 'Caption changes saved.'
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
    $resumeKey = Get-StableHash "$Fingerprint||$DestinationPath||$Encoder||$($script:RenderPipelineVersion)"
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
        CaptionPath = $captionPath
        ResumeDirectory = $resumeDirectory
        HistoryId = $historyEntry.Id
    }
    $RenderProgress.Value = 0
    $script:LastHistoryProgressBucket = -1
    $StatusText.Text = "Starting resumable final render with $Encoder..."
    Set-RenderControls $true
    $script:RenderProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentLine -PassThru -WindowStyle Hidden
    Write-ToolDiagnostic "Resumable final render started. Encoder=$Encoder PID=$($script:RenderProcess.Id)"
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
    $savedPipelineVersion = if ($job.PSObject.Properties['PipelineVersion']) { [string]$job.PipelineVersion } else { '' }
    if ([string]$job.Encoder -ne $encoder -or $savedPipelineVersion -ne $script:RenderPipelineVersion) {
        $job.Encoder = $encoder
        if ($job.PSObject.Properties['PipelineVersion']) { $job.PipelineVersion = $script:RenderPipelineVersion }
        else { $job | Add-Member -NotePropertyName PipelineVersion -NotePropertyValue $script:RenderPipelineVersion }
        $newResumeKey = Get-StableHash "$($HistoryEntry.Id)||$destination||$encoder||$($script:RenderPipelineVersion)"
        $job.ResumeDirectory = Join-Path (Join-Path $script:DataRoot 'resume') $newResumeKey
        $HistoryEntry.ResumeDirectory = [string]$job.ResumeDirectory
    }
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
        DurationSeconds = [double]$job.Timeline.AudioDurationSeconds; Fingerprint = ''; Encoder = $encoder
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
        Background="#0B1019" Foreground="White" FontFamily="Segoe UI">
    <Window.Resources>
        <Style TargetType="TextBlock"><Setter Property="Foreground" Value="White"/></Style>
        <Style TargetType="Button"><Setter Property="Background" Value="#20293A"/><Setter Property="Foreground" Value="White"/><Setter Property="BorderBrush" Value="#3B4860"/><Setter Property="Padding" Value="12,7"/><Setter Property="Margin" Value="3"/></Style>
    </Window.Resources>
    <Grid Margin="14">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="92"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <StackPanel><TextBlock Text="Render History" FontSize="22" FontWeight="SemiBold"/><TextBlock Text="Completed, failed, paused, and resumable production jobs." Foreground="#8C98AD" Margin="0,4,0,12"/></StackPanel>
        <DataGrid x:Name="HistoryGrid" Grid.Row="1" AutoGenerateColumns="False" CanUserAddRows="False" IsReadOnly="True" SelectionMode="Single"
                  Background="#0F1520" Foreground="White" BorderBrush="#303A4D" GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#263043" AlternatingRowBackground="#141B27">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="95"/>
                <DataGridTextColumn Header="Type" Binding="{Binding Type}" Width="70"/>
                <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="180"/>
                <DataGridTextColumn Header="Started" Binding="{Binding Started}" Width="145"/>
                <DataGridTextColumn Header="Progress" Binding="{Binding Progress}" Width="80"/>
                <DataGridTextColumn Header="Output" Binding="{Binding OutputPath}" Width="*"/>
            </DataGrid.Columns>
        </DataGrid>
        <Border Grid.Row="2" Background="#151C28" BorderBrush="#2C3649" BorderThickness="1" CornerRadius="7" Padding="10" Margin="0,10">
            <TextBlock x:Name="HistoryDetails" Text="Select a render to see details." Foreground="#AAB4C6" TextWrapping="Wrap"/>
        </Border>
        <Grid Grid.Row="3"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel Orientation="Horizontal"><Button x:Name="OpenHistoryOutputButton" Content="Open Output"/><Button x:Name="OpenHistoryFolderButton" Content="Open Folder"/><Button x:Name="RemoveHistoryButton" Content="Remove" Background="#542735"/><Button x:Name="ClearCompletedButton" Content="Clear Completed"/></StackPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal"><Button x:Name="CloseHistoryButton" Content="Close"/><Button x:Name="ResumeHistoryButton" Content="Resume Selected" Background="#7C3AED" BorderBrush="#9B70F7" FontWeight="SemiBold"/></StackPanel>
        </Grid>
    </Grid>
</Window>
'@
    $reader = [Xml.XmlNodeReader]::new([xml]$historyXaml)
    $historyWindow = [Windows.Markup.XamlReader]::Load($reader)
    $historyWindow.Owner = $window
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

function Show-BulkQueueBuilder {
    # A queue item is deliberately kept small: one image folder, one voiceover,
    # and one output.  The current Motion/Captions settings and watermark are
    # shared by all queue items, so users can prepare many videos in one pass.
    $queueXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Build render queue" Width="960" Height="700" MinWidth="760" MinHeight="520" WindowStartupLocation="CenterOwner" Background="#101522" Foreground="#F7F7FB">
  <Grid Margin="18"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock Text="Add as many videos as you need, then render them one at a time." FontSize="17" FontWeight="SemiBold"/>
    <Grid Grid.Row="1" Margin="0,14,0,12"><Grid.ColumnDefinitions><ColumnDefinition Width="100"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <TextBlock Text="Watermark" VerticalAlignment="Center" Foreground="#B9C1D0"/><TextBox x:Name="WatermarkText" Grid.Column="1" Margin="8,0"/><Button x:Name="BrowseWatermarkButton" Grid.Column="2" Content="Browse" Padding="12,6"/>
    </Grid>
    <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="RowsPanel"/></ScrollViewer>
    <Grid Grid.Row="3" Margin="0,14,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <Button x:Name="AddVideoButton" Content="+ Add Video" Padding="14,8" Background="#322257" BorderBrush="#7045C7"/>
      <Button x:Name="SavedProjectsButton" Grid.Column="2" Content="Render Saved Projects" Padding="14,8" Margin="4,0"/>
      <Button x:Name="RenderAllButton" Grid.Column="3" Content="Render All" Padding="16,8" Margin="4,0" Background="#0B7285" BorderBrush="#22D3EE" FontWeight="SemiBold"/>
    </Grid>
  </Grid>
</Window>
'@
    $reader = [Xml.XmlNodeReader]::new([xml]$queueXaml)
    $dialog = [Windows.Markup.XamlReader]::Load($reader)
    $dialog.Owner = $window
    $watermarkBox = $dialog.FindName('WatermarkText')
    $watermarkBox.Text = $WatermarkText.Text.Trim()
    $rowsPanel = $dialog.FindName('RowsPanel')
    $rows = [Collections.Generic.List[object]]::new()
    $addRow = {
        $number = $rows.Count + 1
        $border = [Windows.Controls.Border]::new()
        $border.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#344056')
        $border.BorderThickness = [Windows.Thickness]::new(1)
        $border.CornerRadius = [Windows.CornerRadius]::new(5)
        $border.Padding = [Windows.Thickness]::new(10)
        $border.Margin = [Windows.Thickness]::new(0, 0, 0, 9)
        $panel = [Windows.Controls.StackPanel]::new(); $border.Child = $panel
        $header = [Windows.Controls.Grid]::new()
        $header.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
        $autoColumn = [Windows.Controls.ColumnDefinition]::new(); $autoColumn.Width = [Windows.GridLength]::Auto; $header.ColumnDefinitions.Add($autoColumn)
        $title = [Windows.Controls.TextBlock]::new(); $title.Text = "Video $number"; $title.FontWeight = 'SemiBold'; $title.FontSize = 14
        $remove = [Windows.Controls.Button]::new(); $remove.Content = 'Remove'; $remove.Padding = [Windows.Thickness]::new(10,4,10,4)
        [Windows.Controls.Grid]::SetColumn($remove, 1); $header.Children.Add($title); $header.Children.Add($remove); $panel.Children.Add($header)
        $imageBox = [Windows.Controls.TextBox]::new(); $audioBox = [Windows.Controls.TextBox]::new(); $outputBox = [Windows.Controls.TextBox]::new()
        foreach ($definition in @(@('Images folder', $imageBox, 'Folder'), @('Voiceover (M4A)', $audioBox, 'Audio'), @('Output MP4', $outputBox, 'Output'))) {
            $grid = [Windows.Controls.Grid]::new(); $grid.Margin = [Windows.Thickness]::new(0,6,0,0)
            $labelColumn = [Windows.Controls.ColumnDefinition]::new(); $labelColumn.Width = [Windows.GridLength]::new(120); $grid.ColumnDefinitions.Add($labelColumn)
            $grid.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
            $browseColumn = [Windows.Controls.ColumnDefinition]::new(); $browseColumn.Width = [Windows.GridLength]::Auto; $grid.ColumnDefinitions.Add($browseColumn)
            $label = [Windows.Controls.TextBlock]::new(); $label.Text = $definition[0]; $label.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#B9C1D0'); $label.VerticalAlignment = 'Center'
            $box = $definition[1]; [Windows.Controls.Grid]::SetColumn($box,1); $box.Margin = [Windows.Thickness]::new(8,0,8,0)
            $browse = [Windows.Controls.Button]::new(); $browse.Content = 'Browse'; $browse.Padding = [Windows.Thickness]::new(10,4,10,4); [Windows.Controls.Grid]::SetColumn($browse,2)
            $grid.Children.Add($label); $grid.Children.Add($box); $grid.Children.Add($browse); $panel.Children.Add($grid)
            if ($definition[2] -eq 'Folder') { $browse.Add_Click(({ $picked = Select-Folder -Description 'Select images folder'; if ($picked) { $box.Text = $picked } }).GetNewClosure()) }
            elseif ($definition[2] -eq 'Audio') { $browse.Add_Click(({ $picked = Select-OpenFile -Title 'Select M4A voiceover' -Filter 'M4A audio (*.m4a)|*.m4a'; if ($picked) { $box.Text = $picked } }).GetNewClosure()) }
            else { $browse.Add_Click(({ $picked = Select-SaveFile -Title 'Choose output MP4' -Filter 'MP4 video (*.mp4)|*.mp4' -DefaultExtension '.mp4'; if ($picked) { $box.Text = $picked } }).GetNewClosure()) }
        }
        $row = [pscustomobject]@{ Border=$border; ImageBox=$imageBox; AudioBox=$audioBox; OutputBox=$outputBox }
        $remove.Add_Click(({ $rows.Remove($row); [void]$rowsPanel.Children.Remove($border) }).GetNewClosure())
        $rows.Add($row); $rowsPanel.Children.Add($border)
    }.GetNewClosure()
    $dialog.FindName('BrowseWatermarkButton').Add_Click({ $picked = Select-OpenFile -Title 'Select watermark video' -Filter 'Video files (*.mov;*.mp4)|*.mov;*.mp4'; if ($picked) { $watermarkBox.Text = $picked } }.GetNewClosure())
    $dialog.FindName('AddVideoButton').Add_Click({ & $addRow }.GetNewClosure())
    $dialog.FindName('SavedProjectsButton').Add_Click({ $dialog.Tag = 'saved'; $dialog.Close() }.GetNewClosure())
    $dialog.FindName('RenderAllButton').Add_Click({ $dialog.Tag = 'render'; $dialog.Close() }.GetNewClosure())
    & $addRow
    [void]$dialog.ShowDialog()
    if ($dialog.Tag -eq 'saved') { Start-BatchRender; return }
    if ($dialog.Tag -ne 'render') { return }

    try {
        if ($rows.Count -eq 0) { throw 'Add at least one video to the queue.' }
        $settings = Get-UiSettings
        $watermark = $watermarkBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($watermark) -or -not (Test-Path -LiteralPath $watermark -PathType Leaf) -or @('.mov','.mp4') -notcontains [IO.Path]::GetExtension($watermark).ToLowerInvariant()) { throw 'Select a valid MOV or MP4 watermark for the queue.' }
        if (-not (Test-VideoStream $watermark)) { throw 'FFprobe could not read the selected watermark video.' }
        $queueDirectory = Join-Path (Join-Path $script:DataRoot 'queue-projects') ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $queueDirectory -Force | Out-Null
        $projectPaths = [Collections.Generic.List[string]]::new()
        for ($index = 0; $index -lt $rows.Count; $index++) {
            $row = $rows[$index]; $imageFolder = $row.ImageBox.Text.Trim(); $audio = $row.AudioBox.Text.Trim(); $output = $row.OutputBox.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($imageFolder) -or -not (Test-Path -LiteralPath $imageFolder -PathType Container)) { throw "Video $($index + 1): select a valid images folder." }
            if ([string]::IsNullOrWhiteSpace($audio) -or -not (Test-Path -LiteralPath $audio -PathType Leaf) -or [IO.Path]::GetExtension($audio).ToLowerInvariant() -ne '.m4a') { throw "Video $($index + 1): select a valid M4A voiceover." }
            if ([string]::IsNullOrWhiteSpace($output) -or [IO.Path]::GetExtension($output).ToLowerInvariant() -ne '.mp4') { throw "Video $($index + 1): choose an output MP4 file." }
            $outputDirectory = Split-Path -Parent $output
            if ([string]::IsNullOrWhiteSpace($outputDirectory) -or -not (Test-Path -LiteralPath $outputDirectory -PathType Container)) { throw "Video $($index + 1): the output folder does not exist." }
            $images = @(Get-ValidatedImages $imageFolder)
            $duration = Get-MediaDurationSeconds -FfprobePath $script:FfprobePath -MediaPath $audio
            $timeline = New-TimelinePlan -ImagePaths $images -AudioDurationSeconds $duration -MinimumDurationSeconds $settings.MinimumDuration -MaximumDurationSeconds $settings.MaximumDuration -Fps 24
            $project = [ordered]@{ SchemaVersion=1; ImageFolder=$imageFolder; AudioPath=$audio; WatermarkPath=$watermark; OutputPath=$output; Settings=$settings; PlanSignature=(Get-PlanSignature -Images $images -Duration $duration -Settings $settings -AudioPath $audio); Timeline=$timeline }
            $projectPath = Join-Path $queueDirectory ('video-{0:D3}.svp.json' -f ($index + 1))
            [IO.File]::WriteAllText($projectPath, ($project | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false)); $projectPaths.Add($projectPath)
        }
        Start-BatchRender -ProjectPaths $projectPaths.ToArray()
    }
    catch {
        Write-ToolDiagnostic 'Bulk queue preparation failed.' $_.Exception
        Show-ErrorMessage $_.Exception.Message 'Could not build render queue'
    }
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
            $settings = [pscustomobject]@{
                MinimumDuration = [double]$project.Settings.MinimumDuration
                MaximumDuration = [double]$project.Settings.MaximumDuration
                ZoomMaximum = [double]$project.Settings.ZoomMaximum
                BlurAmount = [double]$project.Settings.BlurAmount
                BackgroundBrightness = [double]$project.Settings.BackgroundBrightness
                Quality = [string]$project.Settings.Quality
                CaptionMode = $captionMode
            }
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
            $projectFingerprint = Get-StableHash (([IO.File]::ReadAllText($projectPath, [Text.Encoding]::UTF8)) + "||$encoder||$($script:RenderPipelineVersion)")
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
        }

        if ($existingOutputs.Count -gt 0) {
            $choice = [Windows.MessageBox]::Show($window, "$($existingOutputs.Count) batch output file(s) already exist. Replace each only after its new render succeeds?", 'Confirm batch replacement', [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Warning)
            if ($choice -ne [Windows.MessageBoxResult]::Yes) {
                Remove-CaptionRunDirectory $batchDirectory
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
            DurationSeconds = 1.0
            Encoder = $encoder
            HistoryId = $HistoryId
        }
        $RenderProgress.Value = 0
        $script:LastHistoryProgressBucket = -1
        Set-RenderControls $true
        $StatusText.Text = "Starting batch of $($prepared.Count) projects..."
        $script:RenderProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentLine -PassThru -WindowStyle Hidden
        $renderTimer.Start()
    }
    catch {
        Write-ToolDiagnostic 'Batch preparation failed.' $_.Exception
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
    try {
        $renderTimer.Stop()
        $process.WaitForExit(); $process.Refresh()
        if ($script:CancelRequested) {
            Update-RenderHistoryEntry -Id ([string]$state.HistoryId) -Status 'Paused' -Progress ([int]$RenderProgress.Value) -Detail 'Batch paused by the user; completed videos and segments were kept.'
            $StatusText.Text = 'Batch paused. Finished videos and resumable segments were kept.'
            return
        }
        if ($process.ExitCode -ne 0) {
            $details = 'The batch worker stopped before all projects completed.'
            if (Test-Path -LiteralPath $state.ErrorPath -PathType Leaf) {
                $raw = Get-Content -LiteralPath $state.ErrorPath -Raw -ErrorAction SilentlyContinue
                if (-not [string]::IsNullOrWhiteSpace($raw)) { $details = $raw.Trim() }
            }
            throw $details
        }
        $RenderProgress.Value = 100
        $script:FinalOutputPath = $state.DestinationPath
        $OpenFolderButton.IsEnabled = $true
        Update-RenderHistoryEntry -Id ([string]$state.HistoryId) -Status 'Completed' -Progress 100 -Detail "Completed $(@($state.OutputPaths).Count) videos."
        $StatusText.Text = "Batch completed: $(@($state.OutputPaths).Count) videos."
    }
    catch {
        Write-ToolDiagnostic 'Batch rendering failed.' $_.Exception
        if ($null -ne $state -and $state.PSObject.Properties['HistoryId']) { Update-RenderHistoryEntry -Id ([string]$state.HistoryId) -Status 'Failed' -Progress ([int]$RenderProgress.Value) -Detail $_.Exception.Message }
        Show-ErrorMessage "$($_.Exception.Message)`r`n`r`nCompleted videos and resumable segments were kept." 'Batch rendering stopped'
        $StatusText.Text = 'Batch stopped. You can select the same projects again to resume.'
    }
    finally {
        if ($null -ne $state) { Remove-RenderArtifacts -State $state -KeepErrorLog ($process.ExitCode -ne 0) }
        $script:RenderProcess = $null
        $script:RenderState = $null
        Set-RenderControls $false
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
        if (-not (Test-Path -LiteralPath $audioPath -PathType Leaf) -or [IO.Path]::GetExtension($audioPath).ToLowerInvariant() -ne '.m4a') {
            throw 'Select a valid M4A voiceover file.'
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
            $renderFrames = [Math]::Min(60 * 24, [int]$script:CurrentPlan.TotalFrames)
            Stop-PreviewPlayback
            $PreviewMedia.Source = $null
        }

        $encoder = Select-AvailableEncoder
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
                -Width 1920 -Height 1080
        }
        elseif ($encoder -eq 'h264_vulkan') {
            $definition = New-VulkanFilterGraph `
                -Timeline $script:CurrentPlan `
                -RenderFrames $renderFrames `
                -ZoomMaximumPercent $settings.ZoomMaximum `
                -BlurAmount $settings.BlurAmount `
                -BackgroundBrightnessPercent $settings.BackgroundBrightness `
                -SubtitlePath '' `
                -CaptionPreset $settings.CaptionPreset `
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
        elseif ($encoder -eq 'h264_vulkan') {
            foreach ($value in @(
                    '-init_hw_device', "vulkan=slideshowgpu:$($script:VulkanDeviceIndex)",
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
        foreach ($value in (Get-EncodingArguments -Encoder $encoder -Quality $settings.Quality)) {
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

        $audioPath = Resolve-MissingMediaFile -Path ([string]$project.AudioPath) -Title 'Locate voiceover' -Filter 'M4A audio (*.m4a)|*.m4a'
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
            $CaptionStatusText.Text = "$($captionProgress.Message) ($([Math]::Floor($percentage))%)"
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
    $selected = Select-OpenFile -Title 'Select M4A voiceover' -Filter 'M4A audio (*.m4a)|*.m4a' -InitialPath $AudioText.Text
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

$ImageFolderText.Add_TextChanged({ Invalidate-Preview $true })
$AudioText.Add_TextChanged({
    $script:AudioDurationSeconds = 0.0
    $script:CaptionPath = $null
    $script:LiveCaptionEntries = @()
    $script:LiveCaptionCacheSignature = ''
    $LiveCaptionBorder.Visibility = [Windows.Visibility]::Collapsed
    $CaptionStatusText.Text = 'Captions will be generated locally from this voiceover.'
    Update-Estimate
    Invalidate-Preview $true
})
$WatermarkText.Add_TextChanged({ Invalidate-Preview $false })
$MinimumDurationText.Add_TextChanged({ Invalidate-Preview $true })
$MaximumDurationText.Add_TextChanged({ Invalidate-Preview $true })
$ZoomText.Add_TextChanged({ Invalidate-Preview $false })
$BlurSlider.Add_ValueChanged({ Update-SettingLabels; Invalidate-Preview $false })
$BrightnessSlider.Add_ValueChanged({ Update-SettingLabels; Invalidate-Preview $false })
$QualityCombo.Add_SelectionChanged({ Update-Estimate; Invalidate-Preview $false })
$CaptionModeCombo.Add_SelectionChanged({
    Update-LiveCaptionText
})
$CaptionPresetCombo.Add_SelectionChanged({
    Update-CaptionPresetDescription
    if (-not $script:IsLoading -and -not $script:IsApplyingCaptionPreset) {
        Apply-CaptionPresetToControls (Get-ComboText $CaptionPresetCombo)
        $StatusText.Text = 'Caption preset applied instantly to the preview.'
    }
})

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
$BatchButton.Add_Click({ Show-BulkQueueBuilder })
$RenderHistoryButton.Add_Click({ Show-RenderHistory })

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
$AppSubtitleText.Text = "Slideshow automation studio  ·  v$($script:AppVersion)"
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

$window.ShowDialog() | Out-Null
