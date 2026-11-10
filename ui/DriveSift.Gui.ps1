<#
.SYNOPSIS
    DriveSift 图形界面：磁盘体检 · 优化建议 · 隔离区管理。
.DESCRIPTION
    三个标签页：
    - 清理：按风险级别筛选的候选表 + 归属/重建方式/内容抽查详情 + 隔离操作（只移动，不删除）。
    - 优化建议：基于实测指标的建议 + 白名单快捷操作（只启动系统工具/设置页，绝不静默执行）。
    - 隔离区：条目与保留期列表、还原、手动永久删除（双重确认）、到期清理、自动清理定时任务开关。
    界面本身不做任何推断，所有结论都来自模块（归属索引 + 规则集 + 守卫 + 内容抽查）。
    审计在后台运行，界面不会假死；破坏性操作一律走确认对话框并写入 audit.jsonl 留痕。
.EXAMPLE
    .\ui\DriveSift.Gui.ps1 -ProjectRoot C:\Projects
.EXAMPLE
    .\ui\DriveSift.Gui.ps1 -ValidateOnly
#>
[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [string]$DuplicateRoot,
    [string]$QuarantineRoot,
    [switch]$Fast,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$script:ModuleRoot = Split-Path -Parent $PSScriptRoot
$script:ModulePath = Join-Path $script:ModuleRoot 'DriveSift.psd1'
$script:ReportPath = Join-Path $script:ModuleRoot 'DriveSift-report.html'
$script:SettingsPath = Join-Path $env:LOCALAPPDATA 'DriveSift\settings.json'
$script:CachePath = Join-Path $env:LOCALAPPDATA 'DriveSift\last-audit.json'
$script:Duplicates = @()
$script:AllRows = @()
$script:TierFilter = 'ALL'
$script:LoadedCache = $false
$script:ScanPowerShell = $null
$script:ScanHandle = $null
$script:ScanTimer = $null
$script:BrushCache = @{}
$script:Health = $null
$script:Suggestions = @()
$script:QuarantineRows = @()
$script:RetentionDays = 7

try {
    Import-Module -Name $script:ModulePath -Force -ErrorAction Stop
}
catch {
    [void][System.Windows.MessageBox]::Show("模块加载失败：`n$($_.Exception.Message)`n`n$script:ModulePath", 'DriveSift', 'OK', 'Error')
    exit 1
}

# ---------- 保存上次使用的扫描范围与保留期 ----------
$saved = $null
if (Test-Path -LiteralPath $script:SettingsPath) {
    try { $saved = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json } catch { }
}

$script:ProjectRoot = if ($ProjectRoot) { $ProjectRoot }
elseif ($saved -and $saved.ProjectRoot) { [string]$saved.ProjectRoot }
else { 'C:\' }

$script:DuplicateRoot = if ($DuplicateRoot) { $DuplicateRoot }
elseif ($saved -and $saved.DuplicateRoot) { [string]$saved.DuplicateRoot }
else { $script:ProjectRoot }

if ($saved -and $saved.RetentionDays) {
    $retentionParsed = 0
    if ([int]::TryParse([string]$saved.RetentionDays, [ref]$retentionParsed) -and $retentionParsed -ge 1 -and $retentionParsed -le 365) {
        $script:RetentionDays = $retentionParsed
    }
}

if (-not $QuarantineRoot) {
    # 隔离区放在系统盘之外，否则同盘改名等于没腾出空间
    $systemLetter = $env:SystemDrive.Substring(0, 1).ToUpperInvariant()
    $candidate = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne $systemLetter -and $_.Free -ne $null } |
        Sort-Object -Property Free -Descending)
    $QuarantineRoot = if ($candidate.Count -gt 0) { "$($candidate[0].Name):\_DriveSift-Quarantine" }
    else { Join-Path $env:USERPROFILE 'DriveSift-Quarantine' }
}
$script:QuarantineRoot = $QuarantineRoot

# ---------- 界面定义 ----------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DriveSift · 磁盘体检"
        Height="840" Width="1300" MinHeight="620" MinWidth="1000"
        WindowStartupLocation="CenterScreen"
        Background="#0E1116" Foreground="#E6EAF2" FontSize="13"
        FontFamily="Microsoft YaHei UI, Segoe UI">
  <Window.Resources>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#161A21"/>
      <Setter Property="BorderBrush" Value="#232B36"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="10"/>
    </Style>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Background" Value="#151B24"/>
      <Setter Property="Foreground" Value="#D8E0EC"/>
      <Setter Property="BorderBrush" Value="#252E3B"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1E2733"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#2BD07C"/>
      <Setter Property="Foreground" Value="#04200F"/>
      <Setter Property="BorderBrush" Value="#2BD07C"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
    </Style>

    <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#3A1517"/>
      <Setter Property="Foreground" Value="#F0837A"/>
      <Setter Property="BorderBrush" Value="#5A2226"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
    </Style>

    <Style x:Key="BtnTier" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>

    <Style x:Key="DgHeader" TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#141A22"/>
      <Setter Property="Foreground" Value="#8C97A8"/>
      <Setter Property="BorderBrush" Value="#212834"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Setter Property="Padding" Value="10,10"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
    </Style>

    <Style x:Key="DgCell" TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="10,0"/>
      <Setter Property="Foreground" Value="#D5DDE9"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridCell">
            <Border Background="Transparent" Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="DgRow" TargetType="DataGridRow">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#D5DDE9"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#171E28"/>
        </Trigger>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#1C2A3A"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="KpiLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="#8C97A8"/>
    </Style>
    <Style x:Key="KpiValue" TargetType="TextBlock">
      <Setter Property="FontSize" Value="25"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Margin" Value="0,5,0,2"/>
    </Style>
    <Style x:Key="KpiSub" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Foreground" Value="#78849A"/>
    </Style>
    <Style x:Key="Section" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Foreground" Value="#69758A"/>
      <Setter Property="Margin" Value="0,14,0,5"/>
    </Style>
    <Style x:Key="Body" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Foreground" Value="#B9C4D4"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>

    <Style x:Key="TabHeader" TargetType="TabItem">
      <Setter Property="Foreground" Value="#8C97A8"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="bd" Background="#151B24" BorderBrush="#252E3B"
                    BorderThickness="1,1,1,0" CornerRadius="8,8,0,0" Padding="22,9" Margin="0,0,6,0">
              <ContentPresenter ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#161A21"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="#2BD07C"/>
                <Setter Property="Foreground" Value="#EDF3FB"/>
              </Trigger>
              <MultiTrigger>
                <MultiTrigger.Conditions>
                  <Condition Property="IsSelected" Value="False"/>
                  <Condition Property="IsMouseOver" Value="True"/>
                </MultiTrigger.Conditions>
                <Setter TargetName="bd" Property="Background" Value="#1B2430"/>
              </MultiTrigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Cbx" TargetType="ComboBox">
      <Setter Property="Background" Value="#121722"/>
      <Setter Property="Foreground" Value="#C6D1E1"/>
      <Setter Property="BorderBrush" Value="#232B36"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Width" Value="90"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- 顶部 -->
    <Grid Grid.Row="0" Margin="20,18,20,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>

      <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
        <Border Width="34" Height="34" CornerRadius="9" Background="#2BD07C" VerticalAlignment="Center">
          <TextBlock Text="DS" Foreground="#04200F" FontSize="14" FontWeight="Bold"
                     HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
          <TextBlock Text="DriveSift" FontSize="21" FontWeight="Bold" Foreground="#EDF3FB"/>
          <TextBlock Text="磁盘体检 · 先证明归属，再决定删除" FontSize="11.5" Foreground="#79859A" Margin="0,1,0,0"/>
        </StackPanel>
      </StackPanel>

      <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="16,0,14,0">
        <TextBlock Text="扫描范围" FontSize="12" Foreground="#8C97A8" VerticalAlignment="Center" Margin="0,0,8,0"/>
        <TextBox x:Name="txtScope" Width="300" Height="32" VerticalContentAlignment="Center" IsReadOnly="True"
                 Background="#121722" Foreground="#C6D1E1" BorderBrush="#232B36" BorderThickness="1"
                 FontSize="12" Padding="8,0" ToolTip="点击选择扫描范围"/>
        <Button x:Name="btnBrowse" Content="选择路径" Style="{StaticResource Btn}" Margin="8,0,0,0" Height="32" Padding="12,0"/>
      </StackPanel>

      <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
        <Button x:Name="btnRescan" Content="开始扫描" Style="{StaticResource Btn}" Height="32" Padding="14,0"/>
        <Button x:Name="btnReport" Content="HTML 报告" Style="{StaticResource Btn}" Height="32" Margin="8,0,0,0" Padding="14,0"/>
      </StackPanel>
    </Grid>

    <!-- 三个标签页 -->
    <TabControl x:Name="tabCtrl" Grid.Row="1" Margin="20,14,20,0" Background="Transparent" BorderThickness="0">

      <!-- ========== 清理 ========== -->
      <TabItem Header="清 理" Style="{StaticResource TabHeader}">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>

          <!-- 概览 -->
          <Grid Grid.Row="0" Margin="0,14,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <Border Grid.Column="0" Style="{StaticResource Card}" Padding="16,13" Margin="0,0,8,0">
              <StackPanel>
                <TextBlock Text="系统盘剩余" Style="{StaticResource KpiLabel}"/>
                <TextBlock x:Name="kpiFree" Text="—" Style="{StaticResource KpiValue}" Foreground="#EDF3FB"/>
                <TextBlock x:Name="kpiFreeSub" Text="读取中" Style="{StaticResource KpiSub}"/>
              </StackPanel>
            </Border>

            <Border Grid.Column="1" Style="{StaticResource Card}" Padding="16,13" Margin="0,0,8,0">
              <StackPanel>
                <TextBlock Text="P2 可安全隔离" Style="{StaticResource KpiLabel}"/>
                <TextBlock x:Name="kpiP2" Text="—" Style="{StaticResource KpiValue}" Foreground="#41DE8B"/>
                <TextBlock x:Name="kpiP2Sub" Text="无需人工判断" Style="{StaticResource KpiSub}"/>
              </StackPanel>
            </Border>

            <Border Grid.Column="2" Style="{StaticResource Card}" Padding="16,13" Margin="0,0,8,0">
              <StackPanel>
                <TextBlock Text="P1 需人工确认" Style="{StaticResource KpiLabel}"/>
                <TextBlock x:Name="kpiP1" Text="—" Style="{StaticResource KpiValue}" Foreground="#E8B75C"/>
                <TextBlock x:Name="kpiP1Sub" Text="先看归属与重建方式" Style="{StaticResource KpiSub}"/>
              </StackPanel>
            </Border>

            <Border Grid.Column="3" Style="{StaticResource Card}" Padding="16,13">
              <StackPanel>
                <TextBlock Text="重复文件可回收" Style="{StaticResource KpiLabel}"/>
                <TextBlock x:Name="kpiDup" Text="—" Style="{StaticResource KpiValue}" Foreground="#5AA9F5"/>
                <TextBlock x:Name="kpiDupSub" Text="按内容哈希，已扣除硬链接" Style="{StaticResource KpiSub}"/>
              </StackPanel>
            </Border>
          </Grid>

          <!-- 主体 -->
          <Grid Grid.Row="1" Margin="0,14,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="176"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="316"/>
            </Grid.ColumnDefinitions>

            <Border Grid.Column="0" Style="{StaticResource Card}" Padding="14,14" Margin="0,0,10,0">
              <Grid>
                <Grid.RowDefinitions>
                  <RowDefinition Height="*"/>
                  <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <StackPanel Grid.Row="0">
                  <TextBlock Text="风 险 分 级" FontSize="11" Foreground="#69758A" Margin="0,0,0,9"/>
                  <Button x:Name="btnAll" Content="全部候选" Style="{StaticResource BtnTier}"/>
                  <Button x:Name="btnP2" Content="P2 可直接隔离" Style="{StaticResource BtnTier}"/>
                  <Button x:Name="btnP1" Content="P1 需人工确认" Style="{StaticResource BtnTier}"/>
                  <Button x:Name="btnP0" Content="P0 禁止操作" Style="{StaticResource BtnTier}"/>

                  <Rectangle Height="1" Fill="#232B36" Margin="0,10,0,12"/>

                  <TextBlock Text="图 例" FontSize="11" Foreground="#69758A" Margin="0,0,0,8"/>
                  <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                    <Border Width="9" Height="9" CornerRadius="2" Background="#41DE8B" VerticalAlignment="Center"/>
                    <TextBlock Text="可隔离，随时还原" FontSize="11.5" Foreground="#8C97A8" Margin="8,0,0,0"/>
                  </StackPanel>
                  <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                    <Border Width="9" Height="9" CornerRadius="2" Background="#E8B75C" VerticalAlignment="Center"/>
                    <TextBlock Text="有引用或需确认" FontSize="11.5" Foreground="#8C97A8" Margin="8,0,0,0"/>
                  </StackPanel>
                  <StackPanel Orientation="Horizontal">
                    <Border Width="9" Height="9" CornerRadius="2" Background="#F0685C" VerticalAlignment="Center"/>
                    <TextBlock Text="受保护，永不执行" FontSize="11.5" Foreground="#8C97A8" Margin="8,0,0,0"/>
                  </StackPanel>

                  <Rectangle Height="1" Fill="#232B36" Margin="0,12,0,12"/>
                  <TextBlock Text="隔 离 区" FontSize="11" Foreground="#69758A" Margin="0,0,0,6"/>
                  <TextBlock x:Name="lblQuarantinePath" Text="" FontSize="11" Foreground="#7C8798" TextWrapping="Wrap"/>
                </StackPanel>

                <TextBlock x:Name="lblCount" Grid.Row="1" Text="尚未扫描" FontSize="11" Foreground="#69758A" Margin="0,10,0,0"/>
              </Grid>
            </Border>

            <Grid Grid.Column="1" Margin="0,0,10,0">
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>

              <Grid Grid.Row="0" Margin="0,0,0,10">
                <TextBox x:Name="txtSearch" Height="34" VerticalContentAlignment="Center"
                         Background="#121722" Foreground="#D5DDE9" BorderBrush="#232B36" BorderThickness="1"
                         FontSize="12.5" Padding="10,0"/>
                <TextBlock x:Name="hint" Text="搜索名称、路径、归属、类别…" IsHitTestVisible="False"
                           Foreground="#5E6A7E" FontSize="12.5" VerticalAlignment="Center" Margin="12,0,0,0"/>
              </Grid>

              <Border Grid.Row="1" Style="{StaticResource Card}" Padding="0" ClipToBounds="True">
                <DataGrid x:Name="gridCandidates"
                          Background="Transparent" BorderThickness="0" Foreground="#D5DDE9"
                          GridLinesVisibility="None" HeadersVisibility="Column" RowHeaderWidth="0"
                          AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False"
                          CanUserResizeRows="False" SelectionMode="Extended" SelectionUnit="FullRow"
                          RowHeight="38" FontSize="12.5"
                          HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Auto"
                          ColumnHeaderStyle="{StaticResource DgHeader}"
                          CellStyle="{StaticResource DgCell}"
                          RowStyle="{StaticResource DgRow}">
                  <DataGrid.Columns>
                    <DataGridTemplateColumn Header="级别" Width="58" SortMemberPath="Tier">
                      <DataGridTemplateColumn.CellTemplate>
                        <DataTemplate>
                          <Border Background="{Binding TierBg}" CornerRadius="4" Padding="7,2" HorizontalAlignment="Left">
                            <TextBlock Text="{Binding TierShort}" Foreground="{Binding TierFg}" FontSize="11" FontWeight="SemiBold"/>
                          </Border>
                        </DataTemplate>
                      </DataGridTemplateColumn.CellTemplate>
                    </DataGridTemplateColumn>

                    <DataGridTextColumn Header="名称" Binding="{Binding Name}" Width="*" MinWidth="150"/>

                    <DataGridTextColumn Header="大小" Binding="{Binding SizeText}" Width="78" SortMemberPath="SizeMB">
                      <DataGridTextColumn.ElementStyle>
                        <Style TargetType="TextBlock">
                          <Setter Property="HorizontalAlignment" Value="Right"/>
                          <Setter Property="TextAlignment" Value="Right"/>
                        </Style>
                      </DataGridTextColumn.ElementStyle>
                    </DataGridTextColumn>

                    <DataGridTextColumn Header="类别" Binding="{Binding Category}" Width="84"/>
                    <DataGridTextColumn Header="归属" Binding="{Binding OwnerText}" Width="104"/>
                  </DataGrid.Columns>
                </DataGrid>
              </Border>
            </Grid>

            <Border Grid.Column="2" Style="{StaticResource Card}" Padding="16,14">
              <Grid>
                <Grid.RowDefinitions>
                  <RowDefinition Height="*"/>
                  <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                  <StackPanel>
                    <TextBlock x:Name="detName" Text="未选择候选" FontSize="16" FontWeight="Bold"
                               Foreground="#EDF3FB" TextWrapping="Wrap"/>
                    <StackPanel Orientation="Horizontal" Margin="0,9,0,0">
                      <Border x:Name="detTierBox" Background="#1E2733" CornerRadius="4" Padding="7,2">
                        <TextBlock x:Name="detTier" Text="—" FontSize="11" Foreground="#9AA6B8" FontWeight="SemiBold"/>
                      </Border>
                      <TextBlock x:Name="detCategory" Text="" FontSize="11.5" Foreground="#7C8798" Margin="9,2,0,0"/>
                    </StackPanel>

                    <TextBlock x:Name="detSize" Text="" Style="{StaticResource Body}" Margin="0,10,0,0" FontSize="12" Foreground="#8C97A8"/>

                    <TextBlock Text="路 径" Style="{StaticResource Section}"/>
                    <TextBox x:Name="detPaths" Text="" IsReadOnly="True" TextWrapping="Wrap"
                             Background="#121722" Foreground="#A9B6C8" BorderBrush="#232B36"
                             BorderThickness="1" FontSize="11.5" Padding="8,6" Height="86"
                             VerticalScrollBarVisibility="Auto"/>

                    <TextBlock Text="为 什 么" Style="{StaticResource Section}"/>
                    <TextBlock x:Name="detReasons" Text="" Style="{StaticResource Body}"/>

                    <TextBlock Text="内 容 抽 查" Style="{StaticResource Section}" x:Name="lblContentTitle" Visibility="Collapsed"/>
                    <TextBlock x:Name="detContent" Text="" Style="{StaticResource Body}" Foreground="#7C8798" Visibility="Collapsed"/>

                    <TextBlock Text="删 了 怎 么 回 来" Style="{StaticResource Section}"/>
                    <TextBlock x:Name="detRebuild" Text="" Style="{StaticResource Body}"/>

                    <TextBlock Text="备 注" Style="{StaticResource Section}" x:Name="lblNotesTitle" Visibility="Collapsed"/>
                    <TextBlock x:Name="detNotes" Text="" Style="{StaticResource Body}" Foreground="#7C8798" Visibility="Collapsed"/>
                  </StackPanel>
                </ScrollViewer>

                <StackPanel Grid.Row="1" Margin="0,14,0,0">
                  <Button x:Name="btnQuarantine" Content="隔离选中（0）" Style="{StaticResource BtnPrimary}"
                          IsEnabled="False" Height="38"/>
                  <TextBlock Text="只移动、不删除；保留期内可随时原位还原，到期条目在隔离区里处理"
                             FontSize="10.5" Foreground="#7C8798" TextWrapping="Wrap" Margin="0,7,0,0"/>
                </StackPanel>
              </Grid>
            </Border>
          </Grid>
        </Grid>
      </TabItem>

      <!-- ========== 优化建议 ========== -->
      <TabItem Header="优化建议" Style="{StaticResource TabHeader}">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <!-- 概览 -->
          <Grid Grid.Row="0" Margin="0,14,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <Border Grid.Column="0" Style="{StaticResource Card}" Padding="16,13" Margin="0,0,8,0">
              <StackPanel>
                <TextBlock Text="系统盘剩余" Style="{StaticResource KpiLabel}"/>
                <TextBlock x:Name="kpiOptFree" Text="—" Style="{StaticResource KpiValue}" Foreground="#EDF3FB"/>
                <TextBlock x:Name="kpiOptFreeSub" Text="审计后显示" Style="{StaticResource KpiSub}"/>
              </StackPanel>
            </Border>

            <Border Grid.Column="1" Style="{StaticResource Card}" Padding="16,13" Margin="0,0,8,0">
              <StackPanel>
                <TextBlock Text="内存" Style="{StaticResource KpiLabel}"/>
                <TextBlock x:Name="kpiOptMem" Text="—" Style="{StaticResource KpiValue}" Foreground="#EDF3FB"/>
                <TextBlock x:Name="kpiOptMemSub" Text="审计后显示" Style="{StaticResource KpiSub}"/>
              </StackPanel>
            </Border>

            <Border Grid.Column="2" Style="{StaticResource Card}" Padding="16,13" Margin="0,0,8,0">
              <StackPanel>
                <TextBlock Text="存储介质" Style="{StaticResource KpiLabel}"/>
                <TextBlock x:Name="kpiOptDisk" Text="—" Style="{StaticResource KpiValue}" Foreground="#EDF3FB"/>
                <TextBlock x:Name="kpiOptDiskSub" Text="审计后显示" Style="{StaticResource KpiSub}"/>
              </StackPanel>
            </Border>

            <Border Grid.Column="3" Style="{StaticResource Card}" Padding="16,13">
              <StackPanel>
                <TextBlock Text="开机自启动" Style="{StaticResource KpiLabel}"/>
                <TextBlock x:Name="kpiOptStartup" Text="—" Style="{StaticResource KpiValue}" Foreground="#EDF3FB"/>
                <TextBlock x:Name="kpiOptStartupSub" Text="审计后显示" Style="{StaticResource KpiSub}"/>
              </StackPanel>
            </Border>
          </Grid>

          <!-- 建议列表 -->
          <Grid Grid.Row="1" Margin="0,12,0,0">
            <Grid.RowDefinitions>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <Border Grid.Row="0" Style="{StaticResource Card}" Padding="0" ClipToBounds="True">
              <DataGrid x:Name="gridSuggestions"
                        Background="Transparent" BorderThickness="0" Foreground="#D5DDE9"
                        GridLinesVisibility="None" HeadersVisibility="Column" RowHeaderWidth="0"
                        AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False"
                        CanUserResizeRows="False" SelectionMode="Single" SelectionUnit="FullRow"
                        RowHeight="38" FontSize="12.5"
                        HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Auto"
                        ColumnHeaderStyle="{StaticResource DgHeader}"
                        CellStyle="{StaticResource DgCell}"
                        RowStyle="{StaticResource DgRow}">
                <DataGrid.Columns>
                  <DataGridTemplateColumn Header="级别" Width="64">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate>
                        <Border Background="{Binding SevBg}" CornerRadius="4" Padding="7,2" HorizontalAlignment="Left" VerticalAlignment="Center">
                          <TextBlock Text="{Binding SevLabel}" Foreground="{Binding SevFg}" FontSize="11" FontWeight="SemiBold"/>
                        </Border>
                      </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>

                  <DataGridTextColumn Header="建议" Binding="{Binding Title}" Width="250"/>

                  <DataGridTemplateColumn Header="说明" Width="*">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate>
                        <TextBlock Text="{Binding Detail}" Foreground="#9AA6B8" FontSize="12"
                                   TextTrimming="CharacterEllipsis" VerticalAlignment="Center"
                                   ToolTip="{Binding Detail}"/>
                      </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>

                  <DataGridTextColumn Header="动作" Binding="{Binding ActionLabel}" Width="150"/>
                </DataGrid.Columns>
              </DataGrid>
            </Border>

            <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,10,0,0">
              <Button x:Name="btnSugAction" Content="执行所选建议的动作" Style="{StaticResource BtnPrimary}"
                      Height="34" Padding="18,0" IsEnabled="False"/>
              <TextBlock x:Name="lblSugHint" Text="建议只是诊断与指引：动作只会打开 Windows 自带工具或设置页，由你确认后再操作"
                         FontSize="11" Foreground="#7C8798" VerticalAlignment="Center" Margin="12,0,0,0"/>
            </StackPanel>
          </Grid>

          <!-- 快捷操作 -->
          <StackPanel Grid.Row="2" Margin="0,16,0,0">
            <TextBlock Text="快 捷 操 作（白名单，均为可见窗口；标注管理员的需要 UAC 确认）" FontSize="11" Foreground="#69758A" Margin="0,0,0,8"/>
            <WrapPanel x:Name="quickActionsPanel"/>
          </StackPanel>
        </Grid>
      </TabItem>

      <!-- ========== 隔离区 ========== -->
      <TabItem Header="隔离区" Style="{StaticResource TabHeader}">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <!-- 概览 -->
          <Grid Grid.Row="0" Margin="0,14,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <Border Grid.Column="0" Style="{StaticResource Card}" Padding="16,13" Margin="0,0,8,0">
              <StackPanel>
                <TextBlock Text="隔离总量" Style="{StaticResource KpiLabel}"/>
                <TextBlock x:Name="kpiQSize" Text="—" Style="{StaticResource KpiValue}" Foreground="#EDF3FB"/>
                <TextBlock x:Name="kpiQSizeSub" Text="刷新后显示" Style="{StaticResource KpiSub}"/>
              </StackPanel>
            </Border>

            <Border Grid.Column="1" Style="{StaticResource Card}" Padding="16,13" Margin="0,0,8,0">
              <StackPanel>
                <TextBlock Text="条目数" Style="{StaticResource KpiLabel}"/>
                <TextBlock x:Name="kpiQCount" Text="—" Style="{StaticResource KpiValue}" Foreground="#EDF3FB"/>
                <TextBlock x:Name="kpiQCountSub" Text="可整批还原" Style="{StaticResource KpiSub}"/>
              </StackPanel>
            </Border>

            <Border Grid.Column="2" Style="{StaticResource Card}" Padding="16,13" Margin="0,0,8,0">
              <StackPanel>
                <TextBlock Text="已过保留期" Style="{StaticResource KpiLabel}"/>
                <TextBlock x:Name="kpiQExpired" Text="—" Style="{StaticResource KpiValue}" Foreground="#F0837A"/>
                <TextBlock x:Name="kpiQExpiredSub" Text="可核对后永久删除" Style="{StaticResource KpiSub}"/>
              </StackPanel>
            </Border>

            <Border Grid.Column="3" Style="{StaticResource Card}" Padding="16,13">
              <StackPanel>
                <TextBlock Text="保留天数（移入时生效）" Style="{StaticResource KpiLabel}"/>
                <ComboBox x:Name="cbxRetention" Style="{StaticResource Cbx}" Margin="0,7,0,0"/>
                <TextBlock x:Name="lblRetentionHint" Text="新移入条目按此天数保留；已有条目按移入时的天数" FontSize="10.5" Foreground="#78849A" TextWrapping="Wrap" Margin="0,4,0,0"/>
              </StackPanel>
            </Border>
          </Grid>

          <!-- 条目列表 -->
          <Border Grid.Row="1" Style="{StaticResource Card}" Padding="0" ClipToBounds="True" Margin="0,12,0,0">
            <DataGrid x:Name="gridQuarantine"
                      Background="Transparent" BorderThickness="0" Foreground="#D5DDE9"
                      GridLinesVisibility="None" HeadersVisibility="Column" RowHeaderWidth="0"
                      AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False"
                      CanUserResizeRows="False" SelectionMode="Extended" SelectionUnit="FullRow"
                      RowHeight="36" FontSize="12.5"
                      HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Auto"
                      ColumnHeaderStyle="{StaticResource DgHeader}"
                      CellStyle="{StaticResource DgCell}"
                      RowStyle="{StaticResource DgRow}">
              <DataGrid.Columns>
                <DataGridTemplateColumn Header="级别" Width="56">
                  <DataGridTemplateColumn.CellTemplate>
                    <DataTemplate>
                      <Border Background="{Binding TierBg}" CornerRadius="4" Padding="7,2" HorizontalAlignment="Left" VerticalAlignment="Center">
                        <TextBlock Text="{Binding TierShort}" Foreground="{Binding TierFg}" FontSize="11" FontWeight="SemiBold"/>
                      </Border>
                    </DataTemplate>
                  </DataGridTemplateColumn.CellTemplate>
                </DataGridTemplateColumn>

                <DataGridTextColumn Header="名称" Binding="{Binding Name}" Width="180"/>

                <DataGridTemplateColumn Header="剩余保留" Width="96">
                  <DataGridTemplateColumn.CellTemplate>
                    <DataTemplate>
                      <Border Background="{Binding LeftBg}" CornerRadius="4" Padding="7,2" HorizontalAlignment="Left" VerticalAlignment="Center">
                        <TextBlock Text="{Binding LeftText}" Foreground="{Binding LeftFg}" FontSize="11" FontWeight="SemiBold"/>
                      </Border>
                    </DataTemplate>
                  </DataGridTemplateColumn.CellTemplate>
                </DataGridTemplateColumn>

                <DataGridTextColumn Header="大小" Binding="{Binding SizeText}" Width="78">
                  <DataGridTextColumn.ElementStyle>
                    <Style TargetType="TextBlock">
                      <Setter Property="HorizontalAlignment" Value="Right"/>
                      <Setter Property="TextAlignment" Value="Right"/>
                    </Style>
                  </DataGridTextColumn.ElementStyle>
                </DataGridTextColumn>

                <DataGridTextColumn Header="移入时间" Binding="{Binding MovedText}" Width="110"/>

                <DataGridTextColumn Header="原始路径" Binding="{Binding OriginalPath}" Width="*" MinWidth="200"/>
              </DataGrid.Columns>
            </DataGrid>
          </Border>

          <!-- 操作 -->
          <StackPanel Grid.Row="2" Margin="0,12,0,0">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <Button x:Name="btnQRefresh" Grid.Column="0" Content="刷新" Style="{StaticResource Btn}" Height="36" Padding="16,0"/>
              <Button x:Name="btnQRestore" Grid.Column="1" Content="还原选中" Style="{StaticResource Btn}" Height="36" Margin="8,0,0,0" Padding="16,0"/>
              <Button x:Name="btnQPurgeExpired" Grid.Column="2" Content="清理已到期" Style="{StaticResource Btn}" Height="36" Margin="8,0,0,0" Padding="16,0"/>
              <Button x:Name="btnQPurge" Grid.Column="3" Content="永久删除选中" Style="{StaticResource BtnDanger}" Height="36" Margin="8,0,0,0" Padding="16,0"/>
              <StackPanel Grid.Column="5" Orientation="Horizontal">
                <CheckBox x:Name="chkAutoPurge" VerticalAlignment="Center" Foreground="#9AA6B8" FontSize="12"/>
                <TextBlock x:Name="lblAutoPurge" Text="" FontSize="11" Foreground="#7C8798" VerticalAlignment="Center" Margin="6,0,10,0" TextWrapping="Wrap" MaxWidth="260"/>
                <Button x:Name="btnOpenQ" Content="打开目录" Style="{StaticResource Btn}" Height="36" Padding="14,0"/>
              </StackPanel>
            </Grid>
            <TextBlock x:Name="lblQRoot" Text="" FontSize="11" Foreground="#7C8798" Margin="0,8,0,0"/>
            <TextBlock Text="永久删除不可恢复：删除前会做防篡改与尺寸漂移检查，并在 audit.jsonl 留痕；被占用的条目会保留以便重试"
                       FontSize="10.5" Foreground="#7C8798" TextWrapping="Wrap" Margin="0,6,0,0"/>
          </StackPanel>
        </Grid>
      </TabItem>
    </TabControl>

    <!-- 状态栏 -->
    <Grid Grid.Row="2" Margin="20,0,20,14">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <TextBlock x:Name="lblStatus" Grid.Column="0" Text="就绪" FontSize="11.5"
                 Foreground="#7C8798" VerticalAlignment="Center" Margin="0,0,14,0"/>
      <ProgressBar x:Name="bar" Grid.Column="1" Height="4" Minimum="0" Maximum="100" Value="0"
                   Foreground="#2BD07C" Background="#161C26" BorderThickness="0" VerticalAlignment="Center"/>
    </Grid>
  </Grid>
</Window>
'@

$window = [System.Windows.Markup.XamlReader]::Parse($xaml)

# ---------- 元素引用 ----------
$script:el = @{}
foreach ($name in @(
        'txtScope', 'txtSearch', 'hint', 'lblCount', 'gridCandidates',
        'btnRescan', 'btnReport', 'btnBrowse', 'btnAll', 'btnP2', 'btnP1', 'btnP0', 'btnQuarantine',
        'kpiFree', 'kpiFreeSub', 'kpiP2', 'kpiP2Sub', 'kpiP1', 'kpiP1Sub', 'kpiDup', 'kpiDupSub',
        'detName', 'detTierBox', 'detTier', 'detCategory', 'detSize', 'detPaths',
        'detReasons', 'detContent', 'lblContentTitle', 'detRebuild', 'detNotes', 'lblNotesTitle',
        'lblStatus', 'bar', 'lblQuarantinePath', 'tabCtrl',
        'kpiOptFree', 'kpiOptFreeSub', 'kpiOptMem', 'kpiOptMemSub', 'kpiOptDisk', 'kpiOptDiskSub',
        'kpiOptStartup', 'kpiOptStartupSub', 'gridSuggestions', 'btnSugAction', 'lblSugHint', 'quickActionsPanel',
        'kpiQSize', 'kpiQSizeSub', 'kpiQCount', 'kpiQCountSub', 'kpiQExpired', 'kpiQExpiredSub',
        'cbxRetention', 'lblRetentionHint', 'gridQuarantine',
        'btnQRefresh', 'btnQRestore', 'btnQPurgeExpired', 'btnQPurge', 'chkAutoPurge', 'lblAutoPurge', 'btnOpenQ', 'lblQRoot'
    )) {
    $script:el[$name] = $window.FindName($name)
    if (-not $script:el[$name]) { throw "XAML 缺少元素: $name" }
}

$script:el['txtScope'].Text = $script:ProjectRoot
$script:el['lblQuarantinePath'].Text = $script:QuarantineRoot
$script:el['lblQRoot'].Text = "隔离区位置：$script:QuarantineRoot"

# 保留天数下拉框
foreach ($day in @(3, 7, 14, 30)) {
    $item = New-Object System.Windows.Controls.ComboBoxItem
    $item.Content = "$day 天"
    $item.Tag = $day
    $script:el['cbxRetention'].Items.Add($item)
}
$script:el['cbxRetention'].SelectedIndex = 1
foreach ($i in 0..($script:el['cbxRetention'].Items.Count - 1)) {
    if ($script:el['cbxRetention'].Items[$i].Tag -eq $script:RetentionDays) {
        $script:el['cbxRetention'].SelectedIndex = $i
        break
    }
}

# ---------- 工具 ----------
function Get-Brush {
    param([string]$Hex)
    if (-not $script:BrushCache.ContainsKey($Hex)) {
        $script:BrushCache[$Hex] = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Hex)
    }
    return $script:BrushCache[$Hex]
}

function Format-DsSize {
    param($MB)
    if ($null -eq $MB) { return '—' }
    $value = [double]$MB
    if ($value -ge 1024) { return ('{0:N2} GB' -f ($value / 1024)) }
    if ($value -lt 1) { return ('{0:N0} KB' -f ($value * 1024)) }
    return ('{0:N0} MB' -f $value)
}

function Format-DsDate {
    param([string]$Iso)
    if (-not $Iso) { return '—' }
    try { return ([datetime]$Iso).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { return $Iso }
}

function Set-Status {
    param([string]$Text, [string]$Color = '#7C8798')
    $script:el['lblStatus'].Text = $Text
    $script:el['lblStatus'].Foreground = Get-Brush $Color
}

function Write-GuiError {
    param($ErrorRecord)
    try {
        $dir = Split-Path -Parent $script:CachePath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $log = Join-Path $dir 'gui-error.log'
        Add-Content -LiteralPath $log -Encoding UTF8 -Value ("[{0}] {1}`n{2}" -f (Get-Date).ToString('s'), $ErrorRecord.Exception.Message, $ErrorRecord.ScriptStackTrace)
    }
    catch { }
}

function Set-Busy {
    param([bool]$Busy)
    $script:el['bar'].IsIndeterminate = $false
    if (-not $Busy) { $script:el['bar'].Value = 100 }
    $script:el['btnRescan'].IsEnabled = -not $Busy
    $script:el['btnBrowse'].IsEnabled = -not $Busy
}

# ---------- 行模型 ----------
function Get-TierStyle {
    param([string]$Tier)
    switch ($Tier) {
        'P2' { @{ Bg = '#123024'; Fg = '#41DE8B'; Label = 'P2 安全'; Short = 'P2' } }
        'P1' { @{ Bg = '#33290F'; Fg = '#E8B75C'; Label = 'P1 确认'; Short = 'P1' } }
        'P0' { @{ Bg = '#36191A'; Fg = '#F0685C'; Label = 'P0 禁止'; Short = 'P0' } }
        default { @{ Bg = '#1E2733'; Fg = '#9AA6B8'; Label = [string]$Tier; Short = [string]$Tier } }
    }
}

function New-RowModel {
    param($Candidate)

    $style = Get-TierStyle $Candidate.Tier

    $lastWrite = ''
    if ($Candidate.LastWriteUtc) {
        try { $lastWrite = ([datetime]$Candidate.LastWriteUtc).ToLocalTime().ToString('yyyy-MM-dd') } catch { }
    }

    $owner = [string]$Candidate.Owner
    if ($owner -like 'project:*') { $owner = '项目 ' + $owner.Substring(8) }

    [pscustomobject]@{
        Name              = [string]$Candidate.Name
        Tier              = [string]$Candidate.Tier
        TierLabel         = $style.Label
        TierShort         = $style.Short
        TierBg            = Get-Brush $style.Bg
        TierFg            = Get-Brush $style.Fg
        SizeMB            = [double]$Candidate.SizeMB
        SizeText          = Format-DsSize $Candidate.SizeMB
        FileCount         = [int]$Candidate.FileCount
        Category          = [string]$Candidate.Category
        OwnerText         = if ($owner) { $owner } else { '系统 / 工具链' }
        LastWrite         = $lastWrite
        PathText          = (@($Candidate.Paths) -join "`r`n")
        ReasonsText       = (@($Candidate.Reasons) -join "`r`n")
        Rebuild           = if ($Candidate.Rebuild) { [string]$Candidate.Rebuild } else { '无自动重建方式，隔离后仍可原位还原' }
        Notes             = [string]$Candidate.Notes
        ContentChecked    = [int]$Candidate.ContentChecked
        ContentTruncated  = [bool]$Candidate.ContentTruncated
        ContentHits       = [int]$Candidate.ContentHits
        ContentHitKinds   = [string]$Candidate.ContentHitKinds
        ContentHitSamples = @($Candidate.ContentHitSamples)
        ContentTop        = [string]$Candidate.ContentTop
        Raw               = $Candidate
    }
}

function New-SuggestionRow {
    param($Suggestion)

    $sev = @{
        high = @{ Bg = '#36191A'; Fg = '#F0685C'; Label = '紧急' }
        warn = @{ Bg = '#33290F'; Fg = '#E8B75C'; Label = '建议' }
        info = @{ Bg = '#123024'; Fg = '#41DE8B'; Label = '参考' }
    }
    $style = $sev[[string]$Suggestion.Severity]
    if (-not $style) { $style = @{ Bg = '#1E2733'; Fg = '#9AA6B8'; Label = [string]$Suggestion.Severity } }

    $actionId = [string]$Suggestion.ActionId
    $actionLabel = '—（仅参考）'
    if ($actionId) {
        if ($actionId -like 'tab:*') {
            if ($actionId -eq 'tab:cleanup') { $actionLabel = '切换到清理标签页' }
            else { $actionLabel = '切换到隔离区标签页' }
        }
        else {
            $cat = @(Get-DsQuickActionCatalog | Where-Object { $_.Id -eq $actionId }) | Select-Object -First 1
            if ($cat) {
                $actionLabel = '打开「' + $cat.Label + '」'
                if ($cat.RequiresAdmin) { $actionLabel += '（管理员）' }
            }
        }
    }

    [pscustomobject]@{
        Severity    = [string]$Suggestion.Severity
        SevLabel    = $style.Label
        SevBg       = Get-Brush $style.Bg
        SevFg       = Get-Brush $style.Fg
        Title       = [string]$Suggestion.Title
        Detail      = [string]$Suggestion.Detail
        ActionId    = $actionId
        ActionLabel = $actionLabel
    }
}

function New-QuarantineRow {
    param($Entry)

    $style = Get-TierStyle [string]$Entry.Tier

    $leftText = ''
    $leftBg = '#123024'
    $leftFg = '#41DE8B'
    if ($Entry.ExpiryUnknown) {
        $leftText = '需手动确认'
        $leftBg = '#1E2733'; $leftFg = '#9AA6B8'
    }
    elseif ($Entry.Expired) {
        $leftText = '已到期'
        $leftBg = '#36191A'; $leftFg = '#F0685C'
    }
    else {
        $leftText = "剩 $($Entry.DaysLeft) 天"
    }

    [pscustomobject]@{
        Tier         = [string]$Entry.Tier
        TierShort    = $style.Short
        TierBg       = Get-Brush $style.Bg
        TierFg       = Get-Brush $style.Fg
        Name         = [string]$Entry.Name
        EntryId      = [string]$Entry.EntryId
        LeftText     = $leftText
        LeftBg       = Get-Brush $leftBg
        LeftFg       = Get-Brush $leftFg
        SizeMB       = $Entry.SizeMB
        SizeText     = Format-DsSize $Entry.SizeMB
        MovedText    = Format-DsDate ([string]$Entry.MovedAt)
        OriginalPath = [string]$Entry.OriginalPath
        Expired      = [bool]$Entry.Expired
        Exists       = [bool]$Entry.StoredExists
    }
}

# ---------- 筛选与概览 ----------
function Update-TierButtons {
    $map = @(
        @('btnAll', 'ALL'), @('btnP2', 'P2'), @('btnP1', 'P1'), @('btnP0', 'P0')
    )
    foreach ($pair in $map) {
        $btn = $script:el[$pair[0]]
        $active = ($script:TierFilter -eq $pair[1])
        $btn.Background = Get-Brush $(if ($active) { '#1B2A38' } else { '#151B24' })
        $btn.BorderBrush = Get-Brush $(if ($active) { '#2BD07C' } else { '#252E3B' })
        $btn.Foreground = Get-Brush $(if ($active) { '#EDF3FB' } else { '#A9B6C8' })
    }
}

function Apply-Filter {
    $keyword = $script:el['txtSearch'].Text.Trim()
    $rows = @($script:AllRows)

    if ($script:TierFilter -ne 'ALL') {
        $rows = @($rows | Where-Object { $_.Tier -eq $script:TierFilter })
    }
    if ($keyword) {
        $rows = @($rows | Where-Object {
                ($_.Name + ' ' + $_.Category + ' ' + $_.OwnerText + ' ' + $_.PathText) -like "*$keyword*"
            })
    }

    $script:el['gridCandidates'].ItemsSource = $rows
    $script:el['lblCount'].Text = "显示 $($rows.Count) / $($script:AllRows.Count) 条"
    Update-QuarantineButton
}

function Update-Kpi {
    $systemLetter = $env:SystemDrive.Substring(0, 1)
    $drive = Get-PSDrive -Name $systemLetter -ErrorAction SilentlyContinue
    if ($drive) {
        $script:el['kpiFree'].Text = Format-DsSize ($drive.Free / 1MB)
        $total = ($drive.Used + $drive.Free) / 1MB
        $script:el['kpiFreeSub'].Text = ('已用 {0} / 共 {1}' -f (Format-DsSize ($drive.Used / 1MB)), (Format-DsSize $total))
    }

    $p2 = @($script:AllRows | Where-Object { $_.Tier -eq 'P2' })
    $p1 = @($script:AllRows | Where-Object { $_.Tier -eq 'P1' })
    $p2Sum = ($p2 | Measure-Object -Property SizeMB -Sum).Sum
    $p1Sum = ($p1 | Measure-Object -Property SizeMB -Sum).Sum

    $script:el['kpiP2'].Text = Format-DsSize $p2Sum
    $script:el['kpiP2Sub'].Text = "$($p2.Count) 项，可整批隔离"
    $script:el['kpiP1'].Text = Format-DsSize $p1Sum
    $script:el['kpiP1Sub'].Text = "$($p1.Count) 项，需逐条确认"

    $dupSum = ($script:Duplicates | Measure-Object -Property ReclaimableMB -Sum).Sum
    $script:el['kpiDup'].Text = Format-DsSize $dupSum
    $script:el['kpiDupSub'].Text = "$($script:Duplicates.Count) 组重复内容"
}

# ---------- 上次结果缓存 ----------
function Save-Cache {
    param($Data)
    try {
        $dir = Split-Path -Parent $script:CachePath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $payload = [pscustomobject]@{
            GeneratedAt = (Get-Date).ToString('s')
            Candidates  = @($Data.Candidates)
            Duplicates  = @($Data.Duplicates)
            Health      = $Data.Health
            Suggestions = @($Data.Suggestions)
        }
        ($payload | ConvertTo-Json -Depth 10 -Compress) | Set-Content -LiteralPath $script:CachePath -Encoding UTF8
    }
    catch { }
}

function Import-Cache {
    if (-not (Test-Path -LiteralPath $script:CachePath)) { return $false }
    try {
        $cache = Get-Content -LiteralPath $script:CachePath -Raw | ConvertFrom-Json
        $rows = @($cache.Candidates | ForEach-Object { New-RowModel $_ })
        if ($rows.Count -eq 0) { return $false }

        $script:AllRows = $rows
        $script:Duplicates = @($cache.Duplicates)
        if ($cache.PSObject.Properties.Name -contains 'Health' -and $cache.Health) {
            $script:Health = $cache.Health
        }
        if ($cache.PSObject.Properties.Name -contains 'Suggestions' -and $cache.Suggestions) {
            $script:Suggestions = @($cache.Suggestions)
        }
        $script:LoadedCache = $true
        Apply-Filter
        Update-Kpi
        Render-OptTab
        Load-QuarantineTab

        $stamp = if ($cache.GeneratedAt) { ([datetime]$cache.GeneratedAt).ToString('MM-dd HH:mm') } else { '上次' }
        Set-Status "显示上次结果（$stamp）；点击「开始扫描」可重新审计" '#8C97A8'
        return $true
    }
    catch { return $false }
}

# ---------- 详情 ----------
function Reset-Detail {
    $script:el['detName'].Text = '未选择候选'
    $script:el['detTierBox'].Background = Get-Brush '#1E2733'
    $script:el['detTier'].Text = '—'
    $script:el['detTier'].Foreground = Get-Brush '#9AA6B8'
    $script:el['detCategory'].Text = '点选左侧任意一行查看归属与回滚方式'
    $script:el['detSize'].Text = ''
    $script:el['detPaths'].Text = ''
    $script:el['detReasons'].Text = '这里只陈述事实：目录是什么、属于谁、删掉怎么回来。'
    $script:el['detContent'].Text = ''
    $script:el['detContent'].Visibility = 'Collapsed'
    $script:el['lblContentTitle'].Visibility = 'Collapsed'
    $script:el['detRebuild'].Text = '—'
    $script:el['detNotes'].Text = ''
    $script:el['detNotes'].Visibility = 'Collapsed'
    $script:el['lblNotesTitle'].Visibility = 'Collapsed'
}

function Show-Selection {
    $row = $script:el['gridCandidates'].SelectedItem
    if ($null -eq $row) {
        Reset-Detail
        return
    }

    $script:el['detName'].Text = $row.Name
    $script:el['detTierBox'].Background = $row.TierBg
    $script:el['detTier'].Text = $row.TierLabel
    $script:el['detTier'].Foreground = $row.TierFg
    $script:el['detCategory'].Text = "$($row.Category) · $($row.OwnerText)"

    $script:el['detSize'].Text = ('{0}  ·  {1:N0} 个文件  ·  最近修改 {2}' -f `
            $row.SizeText, $row.FileCount, $(if ($row.LastWrite) { $row.LastWrite } else { '未知' }))

    $script:el['detPaths'].Text = $row.PathText
    $script:el['detReasons'].Text = $row.ReasonsText

    # 内容抽查：规则说"是缓存"，这里展示目录里实际装了什么
    if ($row.ContentChecked -gt 0) {
        $script:el['lblContentTitle'].Visibility = 'Visible'
        $script:el['detContent'].Visibility = 'Visible'
        $scope = if ($row.ContentTruncated) { "抽样 {0:N0} 个文件（目录较大，已截断）" -f $row.ContentChecked }
        else { "抽样 {0:N0} 个文件" -f $row.ContentChecked }
        $top = if ($row.ContentTop) { "  主要构成：$($row.ContentTop)" } else { '' }
        if ($row.ContentHits -gt 0) {
            $samples = (@($row.ContentHitSamples) -join "`r`n               ")
            $script:el['detContent'].Text = "$scope`n$top`n发现 $($row.ContentHits) 个疑似个人文件（$($row.ContentHitKinds)）：`r`n               $samples"
            $script:el['detContent'].Foreground = Get-Brush '#F0837A'
        }
        else {
            $script:el['detContent'].Text = "$scope`n$top`n未发现疑似个人文件"
            $script:el['detContent'].Foreground = Get-Brush '#7C8798'
        }
    }
    else {
        $script:el['detContent'].Visibility = 'Collapsed'
        $script:el['lblContentTitle'].Visibility = 'Collapsed'
    }

    $script:el['detRebuild'].Text = $row.Rebuild

    if ($row.Notes) {
        $script:el['detNotes'].Text = $row.Notes
        $script:el['detNotes'].Visibility = 'Visible'
        $script:el['lblNotesTitle'].Visibility = 'Visible'
    }
    else {
        $script:el['detNotes'].Text = ''
        $script:el['detNotes'].Visibility = 'Collapsed'
        $script:el['lblNotesTitle'].Visibility = 'Collapsed'
    }
}

function Update-QuarantineButton {
    $selected = @($script:el['gridCandidates'].SelectedItems)
    $movable = @($selected | Where-Object { $_.Tier -ne 'P0' })
    $sum = ($movable | Measure-Object -Property SizeMB -Sum).Sum

    $script:el['btnQuarantine'].Content = "隔离选中（$($movable.Count)）"
    $script:el['btnQuarantine'].IsEnabled = ($movable.Count -gt 0)
    $script:el['btnQuarantine'].ToolTip = if ($movable.Count -gt 0) {
        "将移走 $(Format-DsSize $sum)，P0 不在其中"
    }
    else { '先在列表中选择要隔离的行' }
}

# ---------- 审计 ----------
$script:ScanScript = {
    param($ModulePath, $ProjectRoots, $DuplicateRoots, $ReportPath, $FastMode, $Sync, $QuarantineRoot, $RetentionDays)

    Import-Module -Name $ModulePath -Force

    $Sync.Status = '建立归属索引：项目清单与工具链'
    $Sync.Percent = 3
    $ownership = Get-DsOwnership -ProjectRoot $ProjectRoots

    # 逐条规则推进，否则单个 Get-DsCandidate 调用会把进度条卡住好几分钟
    $rules = @(Get-DsRuleSet)
    $candidates = New-Object System.Collections.ArrayList
    $total = [math]::Max(1, $rules.Count)
    $index = 0
    foreach ($rule in $rules) {
        $index++
        $Sync.Status = "统计缓存与环境 $index/$total：$($rule.Name)"
        $Sync.Percent = 6 + [int](48 * $index / $total)
        foreach ($c in @(Get-DsCandidate -Id $rule.Id -Ownership $ownership -Fast:$FastMode)) {
            [void]$candidates.Add($c)
        }
    }

    $duplicates = @()
    if ($DuplicateRoots.Count -gt 0) {
        $Sync.Status = '按内容哈希查找重复文件'
        $Sync.Percent = 60
        $duplicates = @(Find-DsDuplicate -Path $DuplicateRoots -MinSize 1MB -Ownership $ownership -Fast:$FastMode)
    }

    # 系统体检 + 优化建议（只读，秒级）
    $Sync.Status = '系统体检与优化建议'
    $Sync.Percent = 74
    $health = $null
    $suggestions = @()
    try {
        $health = Get-DsSystemHealth -QuarantineRoot $QuarantineRoot -DefaultRetentionDays $RetentionDays
        $suggestions = @(Get-DsOptimizationSuggestion -Health $health -Candidate @($candidates) -QuarantineRoot $QuarantineRoot)
    }
    catch { $Sync.Status = "体检跳过（$($_.Exception.Message)）" }

    $Sync.Status = '生成 HTML 归档报告'
    $Sync.Percent = 92
    $null = New-DsReport -Candidate @($candidates) -Duplicate $duplicates -Ownership $ownership -OutFile $ReportPath

    $Sync.Percent = 100
    $Sync.Status = '完成'
    [pscustomobject]@{
        Candidates  = @($candidates)
        Duplicates  = $duplicates
        Ownership   = $ownership
        ReportPath  = $ReportPath
        Health      = $health
        Suggestions = $suggestions
    }
}

function Start-Scan {
    if ($script:ScanPowerShell) { return }

    $root = $script:el['txtScope'].Text.Trim()
    if (-not $root -or -not (Test-Path -LiteralPath $root)) {
        Set-Status '扫描范围无效，请先选择一个存在的目录' '#F0685C'
        return
    }
    $script:ProjectRoot = $root
    $script:DuplicateRoot = $root

    try {
        $dir = Split-Path -Parent $script:SettingsPath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $settingsObj = [pscustomobject]@{
            ProjectRoot     = $root
            DuplicateRoot   = $root
            RetentionDays   = $script:RetentionDays
            QuarantineRoot  = $script:QuarantineRoot
        }
        ($settingsObj | ConvertTo-Json) | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
    }
    catch { }

    # 有缓存时保留旧结果，避免界面在扫描期间空着
    if (-not $script:LoadedCache) {
        $script:AllRows = @()
        $script:Duplicates = @()
        $script:el['gridCandidates'].ItemsSource = $null
        $script:el['lblCount'].Text = '扫描中…'
        Reset-Detail
        Update-Kpi
    }
    Set-Busy $true
    $script:el['bar'].Value = 0
    if ($script:LoadedCache) {
        Set-Status '后台重新扫描中，当前显示上次结果'
    }
    else {
        Set-Status '开始扫描…'
    }

    $script:ScanSync = [hashtable]::Synchronized(@{ Status = '准备中…' })

    $script:ScanPowerShell = [powershell]::Create()
    [void]$script:ScanPowerShell.AddScript($script:ScanScript.ToString()).AddParameters(@{
            ModulePath     = $script:ModulePath
            ProjectRoots   = @($script:ProjectRoot)
            DuplicateRoots = @($script:DuplicateRoot)
            ReportPath     = $script:ReportPath
            FastMode       = [bool]$Fast
            Sync           = $script:ScanSync
            QuarantineRoot = $script:QuarantineRoot
            RetentionDays  = $script:RetentionDays
        })
    $script:ScanHandle = $script:ScanPowerShell.BeginInvoke()

    if ($script:ScanTimer) { $script:ScanTimer.Stop() }
    $script:ScanTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ScanTimer.Interval = [TimeSpan]::FromMilliseconds(400)
    $script:ScanTimer.Add_Tick({ Test-ScanState })
    $script:ScanTimer.Start()
}

function Update-ScanState {
    if (-not $script:ScanPowerShell) { return }
    if ($null -ne $script:ScanSync.Status) {
        Set-Status ([string]$script:ScanSync.Status)
    }

    if (-not $script:ScanHandle.IsCompleted) {
        $percent = $script:ScanSync.Percent
        if ($null -ne $percent) { $script:el['bar'].Value = [double]$percent }
        elseif ($script:el['bar'].Value -lt 88) { $script:el['bar'].Value += 1.2 }
        return
    }

    $script:ScanTimer.Stop()
    $data = $null
    $failure = $null
    try {
        $output = @($script:ScanPowerShell.EndInvoke($script:ScanHandle))
        $errors = @($script:ScanPowerShell.Streams.Error)
        if ($output.Count -eq 0 -and $errors.Count -gt 0) { throw $errors[0].Exception }
        $data = $output[0]
    }
    catch {
        $failure = $_.Exception.Message
    }
    finally {
        $script:ScanPowerShell.Dispose()
        $script:ScanPowerShell = $null
        $script:ScanHandle = $null
        Set-Busy $false
    }

    if ($failure) {
        Set-Status "审计中断：$failure" '#F0685C'
        $script:el['bar'].Value = 0
        $script:el['lblCount'].Text = '扫描失败'
        return
    }

    $script:AllRows = @($data.Candidates | ForEach-Object { New-RowModel $_ })
    $script:Duplicates = @($data.Duplicates)
    if ($data.PSObject.Properties.Name -contains 'Health' -and $data.Health) { $script:Health = $data.Health }
    if ($data.PSObject.Properties.Name -contains 'Suggestions') { $script:Suggestions = @($data.Suggestions) }
    if ($data.ReportPath) { $script:ReportPath = [string]$data.ReportPath }
    Save-Cache $data

    Apply-Filter
    Update-Kpi
    Render-OptTab
    Load-QuarantineTab
    $script:el['bar'].Value = 100
    Set-Status ("审计完成：$($script:AllRows.Count) 个候选，$($script:Duplicates.Count) 组重复，$($script:Suggestions.Count) 条建议，报告已生成") '#41DE8B'
}

function Test-ScanState {
    # 定时器里的异常会直接终止整个界面，这里兜住并留痕
    try {
        Update-ScanState
    }
    catch {
        if ($script:ScanTimer) { $script:ScanTimer.Stop() }
        Write-GuiError $_
        Set-Status "界面异常：$($_.Exception.Message)" '#F0685C'
    }
}

# ---------- 隔离 ----------
function Invoke-Quarantine {
    $selected = @($script:el['gridCandidates'].SelectedItems)
    $movable = @($selected | Where-Object { $_.Tier -ne 'P0' })
    if ($movable.Count -eq 0) { return }

    $sum = ($movable | Measure-Object -Property SizeMB -Sum).Sum
    $p1 = @($movable | Where-Object { $_.Tier -eq 'P1' }).Count
    $contentHits = ($movable | Measure-Object -Property ContentHits -Sum).Sum
    $message = "将把 $($movable.Count) 项（$(Format-DsSize $sum)）移入隔离区：`n$script:QuarantineRoot`n`n"
    if ($p1 -gt 0) { $message += "其中 $p1 项为 P1（存在引用或需人工确认），请确认你已看过归属。`n`n" }
    if ($contentHits -gt 0) {
        $hitNames = @($movable | Where-Object { $_.ContentHits -gt 0 } | ForEach-Object { $_.Name }) -join '、'
        $message += "内容抽查在以下条目里发现了疑似个人文件（$hitNames），它们已被降为 P1，请再确认一次。`n`n"
    }
    $message += "不会删除任何文件；保留 $($script:RetentionDays) 天内可随时原位还原，到期后需你确认才会永久删除。继续？"

    $answer = [System.Windows.MessageBox]::Show($message, '确认隔离', 'YesNo', 'Question')
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }

    Set-Status '正在移动…'
    $script:el['btnQuarantine'].IsEnabled = $false

    $results = @()
    try {
        $results = @(Move-DsToQuarantine -Candidate @($movable | ForEach-Object { $_.Raw }) `
                -QuarantineRoot $script:QuarantineRoot -RetentionDays $script:RetentionDays -IncludePending -Confirm:$false)
    }
    catch {
        Set-Status "隔离失败：$($_.Exception.Message)" '#F0685C'
        Update-QuarantineButton
        return
    }

    $done = @($results | Where-Object { $_.Action -eq 'Quarantined' })
    $failed = @($results | Where-Object { $_.Action -eq 'Failed' })
    $freed = ($done | Measure-Object -Property SizeMB -Sum).Sum

    # 路径都不存在的行从列表里移除；部分失败的保留，方便重试
    $script:AllRows = @($script:AllRows | Where-Object {
            $paths = @($_.Raw.Paths)
            @($paths | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0
        })

    Apply-Filter
    Update-Kpi
    Load-QuarantineTab

    if ($failed.Count -gt 0) {
        Set-Status "已隔离 $($done.Count) 项（$(Format-DsSize $freed)），$($failed.Count) 项被占用未移动" '#E8B75C'
    }
    else {
        Set-Status "已隔离 $($done.Count) 项，释放 $(Format-DsSize $freed)；保留期内可在隔离区还原" '#41DE8B'
    }
    $script:el['bar'].Value = 100
}

# ---------- 隔离区标签页 ----------
function Update-QuarantineButtons {
    $selected = @($script:el['gridQuarantine'].SelectedItems | Where-Object { $_.Exists })
    $script:el['btnQRestore'].Content = "还原选中（$($selected.Count)）"
    $script:el['btnQPurge'].Content = "永久删除选中（$($selected.Count)）"
}

function Load-QuarantineTab {
    $rows = @()
    try {
        $entries = @(Get-DsQuarantine -QuarantineRoot $script:QuarantineRoot -DefaultRetentionDays $script:RetentionDays)
        $rows = @($entries | ForEach-Object { New-QuarantineRow $_ })
    }
    catch {
        # 隔离区不存在等情况下直接显示空表
        $rows = @()
    }

    $script:QuarantineRows = $rows
    $script:el['gridQuarantine'].ItemsSource = $rows

    $totalMB = ($rows | Measure-Object -Property SizeMB -Sum).Sum
    $expired = @($rows | Where-Object { $_.Expired })
    $script:el['kpiQSize'].Text = Format-DsSize $totalMB
    $script:el['kpiQSizeSub'].Text = "位于 $script:QuarantineRoot"
    $script:el['kpiQCount'].Text = [string]$rows.Count
    $script:el['kpiQCountSub'].Text = if ($rows.Count -gt 0) { '可整批还原' } else { '隔离区为空' }
    $script:el['kpiQExpired'].Text = [string]$expired.Count
    $script:el['kpiQExpiredSub'].Text = if ($expired.Count -gt 0) { ('共 ' + (Format-DsSize (($expired | Measure-Object -Property SizeMB -Sum).Sum))) } else { '无到期条目' }

    Update-AutoPurgeState
    Update-QuarantineButtons
}

function Update-AutoPurgeState {
    $checked = $false
    $detail = '未启用'
    try {
        $status = Get-DsAutoPurgeStatus
        if ($status.Registered) {
            $checked = $true
            $task = Get-ScheduledTask -TaskName $status.TaskName -ErrorAction SilentlyContinue
            $detail = if ($task) { '已启用（每天自动清理到期条目，详见任务计划程序）' } else { '已启用' }
        }
    }
    catch { $detail = '状态读取失败' }

    # 避免自己改状态时触发自己的事件
    $script:AutoPurgeGuard = $true
    $script:el['chkAutoPurge'].IsChecked = $checked
    $script:AutoPurgeGuard = $false
    $script:el['chkAutoPurge'].Content = ' 自动清理到期条目'
    $script:el['lblAutoPurge'].Text = $detail
}

function Save-RetentionSetting {
    param([int]$Days)
    $script:RetentionDays = $Days
    try {
        $dir = Split-Path -Parent $script:SettingsPath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $current = $null
        if (Test-Path -LiteralPath $script:SettingsPath) {
            try { $current = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json } catch { }
        }
        if (-not $current) { $current = [pscustomobject]@{ ProjectRoot = $script:ProjectRoot } }
        if ($current.PSObject.Properties.Name -notcontains 'RetentionDays') {
            $current | Add-Member -NotePropertyName 'RetentionDays' -NotePropertyValue $Days
        }
        else { $current.RetentionDays = $Days }
        ($current | ConvertTo-Json) | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
    }
    catch { }
}

# 还原选中：还原是安全操作，单次确认
function Invoke-RestoreQuarantine {
    $selected = @($script:el['gridQuarantine'].SelectedItems | Where-Object { $_.Exists })
    if ($selected.Count -eq 0) {
        Set-Status '先在列表中勾选要还原的条目' '#E8B75C'
        return
    }

    $sum = ($selected | Measure-Object -Property SizeMB -Sum).Sum
    $message = "将把 $($selected.Count) 项（$(Format-DsSize $sum)）移回原始路径。`n`n原路径已被占用的条目会跳过（不覆盖）。继续？"
    $answer = [System.Windows.MessageBox]::Show($message, '确认还原', 'YesNo', 'Question')
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }

    Set-Status '正在还原…'
    try {
        $results = @(Restore-DsQuarantine -QuarantineRoot $script:QuarantineRoot -EntryId @($selected | ForEach-Object { $_.EntryId }) -Confirm:$false)
        $done = @($results | Where-Object { $_.Action -eq 'Restored' }).Count
        Set-Status "已还原 $done 项" '#41DE8B'
    }
    catch {
        Set-Status "还原失败：$($_.Exception.Message)" '#F0685C'
    }
    Load-QuarantineTab
}

# 手动永久删除：双重确认。第一次确认范围，第二次展示完整路径清单。
function Invoke-PurgeQuarantine {
    $selected = @($script:el['gridQuarantine'].SelectedItems | Where-Object { $_.Exists })
    if ($selected.Count -eq 0) {
        Set-Status '先在列表中勾选要永久删除的条目' '#E8B75C'
        return
    }

    $sum = ($selected | Measure-Object -Property SizeMB -Sum).Sum
    $names = @($selected | ForEach-Object { $_.Name }) -join '、'
    $first = "将永久删除以下 $($selected.Count) 项（共 $(Format-DsSize $sum)）：`n`n  $names`n`n永久删除后无法通过本工具恢复。继续？"
    $answer = [System.Windows.MessageBox]::Show($first, '永久删除 · 第一次确认', 'YesNo', 'Warning')
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }

    $paths = ($selected | ForEach-Object { '  ' + $_.OriginalPath }) -join "`n"
    $second = "再次确认：以下路径将被永久删除`n$paths`n`n此操作不可撤销。删除前会自动做防篡改与尺寸漂移检查。确定执行？"
    $answer2 = [System.Windows.MessageBox]::Show($second, '永久删除 · 第二次确认', 'YesNo', 'Warning')
    if ($answer2 -ne [System.Windows.MessageBoxResult]::Yes) { return }

    Set-Status '正在永久删除…'
    try {
        $results = @(Remove-DsQuarantine -QuarantineRoot $script:QuarantineRoot -EntryId @($selected | ForEach-Object { $_.EntryId }) -Confirm:$false)
        $done = @($results | Where-Object { $_.Action -eq 'Purged' }).Count
        $failed = @($results | Where-Object { $_.Action -eq 'Failed' }).Count
        $skipped = @($results | Where-Object { $_.Action -eq 'Skipped' }).Count
        if ($failed -gt 0 -or $skipped -gt 0) {
            Set-Status "已删除 $done 项；$($skipped) 项被安全检查拦截，$($failed) 项删除失败（可重试）" '#E8B75C'
        }
        else {
            Set-Status "已永久删除 $done 项" '#41DE8B'
        }
    }
    catch {
        Set-Status "永久删除失败：$($_.Exception.Message)" '#F0685C'
    }
    Load-QuarantineTab
}

# 清理已到期：执行保留期策略，单次确认（展示完整清单）
function Invoke-PurgeExpired {
    $expired = @($script:QuarantineRows | Where-Object { $_.Expired -and $_.Exists })
    if ($expired.Count -eq 0) {
        Set-Status '没有已过保留期的条目'
        return
    }

    $sum = ($expired | Measure-Object -Property SizeMB -Sum).Sum
    $paths = ($expired | ForEach-Object { '  ' + $_.Name + '  （' + $_.OriginalPath + '）' }) -join "`n"
    $message = "以下 $($expired.Count) 项已超过保留期（共 $(Format-DsSize $sum)），保留期内未被还原：`n`n$paths`n`n永久删除后无法恢复。确定清理？"
    $answer = [System.Windows.MessageBox]::Show($message, '清理已到期条目', 'YesNo', 'Warning')
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }

    Set-Status '正在清理到期条目…'
    try {
        $results = @(Remove-DsQuarantine -QuarantineRoot $script:QuarantineRoot -Expired -Confirm:$false)
        $done = @($results | Where-Object { $_.Action -eq 'Purged' }).Count
        $failed = @($results | Where-Object { $_.Action -eq 'Failed' }).Count
        $skipped = @($results | Where-Object { $_.Action -eq 'Skipped' }).Count
        if ($failed -gt 0 -or $skipped -gt 0) {
            Set-Status "已清理 $done 项；$($skipped) 项被安全检查拦截，$($failed) 项失败（可重试）" '#E8B75C'
        }
        else {
            Set-Status "已清理 $done 项到期条目" '#41DE8B'
        }
    }
    catch {
        Set-Status "清理失败：$($_.Exception.Message)" '#F0685C'
    }
    Load-QuarantineTab
}

# ---------- 优化建议标签页 ----------
function Render-OptTab {
    $health = $script:Health

    # 概览
    if ($health) {
        $sysDrive = @($health.Drives | Where-Object { $_.IsSystem }) | Select-Object -First 1
        if ($sysDrive) {
            $script:el['kpiOptFree'].Text = Format-DsSize ($sysDrive.FreeGB * 1024)
            $script:el['kpiOptFreeSub'].Text = "$($sysDrive.Letter) 剩余 $([math]::Round($sysDrive.FreePercent, 1))%"
            if ($sysDrive.FreePercent -lt 10) { $script:el['kpiOptFree'].Foreground = Get-Brush '#E8B75C' }
        }
        if ($health.MemoryTotalMB) {
            $script:el['kpiOptMem'].Text = ('{0:N1} GB' -f ($health.MemoryTotalMB / 1024))
            $script:el['kpiOptMemSub'].Text = ('可用 ' + (Format-DsSize $health.MemoryFreeMB))
        }
        if (@($health.Disks).Count -gt 0) {
            $ssd = @($health.Disks | Where-Object { $_.IsSsd -eq $true }).Count
            $hdd = @($health.Disks | Where-Object { $_.IsSsd -eq $false }).Count
            $unknown = @($health.Disks | Where-Object { $null -eq $_.IsSsd }).Count
            $parts = @()
            if ($ssd -gt 0) { $parts += "$ssd SSD" }
            if ($hdd -gt 0) { $parts += "$hdd HDD" }
            if ($unknown -gt 0) { $parts += "$unknown 未知" }
            $script:el['kpiOptDisk'].Text = ($parts -join ' / ')
            $script:el['kpiOptDiskSub'].Text = ($health.Disks | ForEach-Object { $_.Name } | Select-Object -First 1)
        }
        if ($null -ne $health.StartupItems -and $null -ne @($health.StartupItems)) {
            $script:el['kpiOptStartup'].Text = [string]@($health.StartupItems).Count
            $script:el['kpiOptStartupSub'].Text = '注册表 Run 键 + 启动文件夹'
        }
    }

    # 建议列表
    $script:el['gridSuggestions'].ItemsSource = @($script:Suggestions | ForEach-Object { New-SuggestionRow $_ })
    $script:el['btnSugAction'].IsEnabled = ($script:Suggestions.Count -gt 0)

    # 快捷操作按钮（代码生成，避免 XAML 解析时绑定事件）
    $panel = $script:el['quickActionsPanel']
    $panel.Children.Clear()
    foreach ($item in @(Get-DsQuickActionCatalog)) {
        $btn = New-Object System.Windows.Controls.Button
        $label = $item.Label
        if ($item.RequiresAdmin) { $label += '（管理员）' }
        $btn.Content = $label
        $btn.Tag = $item.Id
        $btn.ToolTip = $item.Detail
        $btn.Padding = New-Object System.Windows.Thickness(14, 7, 14, 7)
        $btn.Margin = New-Object System.Windows.Thickness(0, 0, 8, 8)
        $btn.Cursor = [System.Windows.Input.Cursors]::Hand
        $btn.Add_Click({
            $sender = $eventArgs.Sender
            try {
                $result = Start-DsQuickAction -Action ([string]$sender.Tag) -Confirm:$false
                if ($result.Launched) {
                    Set-Status "已启动「$($result.Label)」" '#41DE8B'
                }
                else {
                    Set-Status "启动失败（$($result.Label)）：$($result.Error)" '#F0685C'
                }
            }
            catch {
                Set-Status "快捷操作失败：$($_.Exception.Message)" '#F0685C'
            }
        })
    [void]$panel.Children.Add($btn)
}
}

function Invoke-SuggestionAction {
    $row = $script:el['gridSuggestions'].SelectedItem
    if ($null -eq $row -or -not $row.ActionId) {
        Set-Status '所选建议没有可执行的动作（仅参考）' '#E8B75C'
        return
    }

    if ($row.ActionId -like 'tab:*') {
        if ($row.ActionId -eq 'tab:cleanup') {
            $script:el['tabCtrl'].SelectedIndex = 0
            Set-Status '已切换到清理标签页'
        }
        else {
            $script:el['tabCtrl'].SelectedIndex = 2
            Load-QuarantineTab
            Set-Status '已切换到隔离区标签页'
        }
        return
    }

    $answer = [System.Windows.MessageBox]::Show("将启动 Windows 系统工具「$($row.ActionLabel)」。`n启动后请你在系统窗口里自行确认每一步操作。", '执行建议动作', 'YesNo', 'Question')
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }

    try {
        $result = Start-DsQuickAction -Action ([string]$row.ActionId) -Confirm:$false
        if ($result.Launched) {
            Set-Status "已启动「$($result.Label)」" '#41DE8B'
        }
        else {
            Set-Status "启动失败（$($result.Label)）：$($result.Error)" '#F0685C'
        }
    }
    catch {
        Set-Status "快捷操作失败：$($_.Exception.Message)" '#F0685C'
    }
}

# ---------- 事件 ----------
$script:el['btnAll'].Add_Click({ $script:TierFilter = 'ALL'; Update-TierButtons; Apply-Filter })
$script:el['btnP2'].Add_Click({ $script:TierFilter = 'P2'; Update-TierButtons; Apply-Filter })
$script:el['btnP1'].Add_Click({ $script:TierFilter = 'P1'; Update-TierButtons; Apply-Filter })
$script:el['btnP0'].Add_Click({ $script:TierFilter = 'P0'; Update-TierButtons; Apply-Filter })

$script:el['txtSearch'].Add_TextChanged({
    if ($script:el['txtSearch'].Text) { $script:el['hint'].Visibility = 'Collapsed' }
    else { $script:el['hint'].Visibility = 'Visible' }
    Apply-Filter
})

$script:el['gridCandidates'].Add_SelectionChanged({
    Show-Selection
    Update-QuarantineButton
})

# Ctrl+A 全选快捷键（候选列表与隔离区列表；WPF 表格默认不响应 Ctrl+A）
foreach ($gridName in @('gridCandidates', 'gridQuarantine')) {
    $script:el[$gridName].Add_PreviewKeyDown({
        param($sender, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::A -and
            [System.Windows.Input.Keyboard]::ModifierKeys -band [System.Windows.Input.ModifierKeys]::Control) {
            [void]$sender.SelectAll()
            $e.Handled = $true
        }
    })
}

$script:el['btnQuarantine'].Add_Click({ Invoke-Quarantine })
$script:el['btnRescan'].Add_Click({ Start-Scan })

# 路径选择弹窗：只改范围，不自动扫描；扫描由「开始扫描」手动触发
function Invoke-ChooseScope {
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    # 注意：PS 5.1 的 .NET Framework 版 FolderBrowserDialog 没有 UseDescriptionForTitle 属性（那是 OpenFileDialog 的），设置它会直接抛异常
    $dialog.Description = '选择扫描范围'
    $current = $script:el['txtScope'].Text.Trim()
    if ($current -and (Test-Path -LiteralPath $current -PathType Container)) { $dialog.SelectedPath = $current }
    if ($dialog.ShowDialog() -eq 'OK') {
        $script:el['txtScope'].Text = $dialog.SelectedPath
        Set-Status "扫描范围：$($dialog.SelectedPath)；点击「开始扫描」开始审计"
    }
}
$script:el['btnBrowse'].Add_Click({ Invoke-ChooseScope })
$script:el['txtScope'].Add_MouseLeftButtonUp({ Invoke-ChooseScope })

$script:el['btnReport'].Add_Click({
    if (-not (Test-Path -LiteralPath $script:ReportPath)) {
        [void][System.Windows.MessageBox]::Show('报告尚未生成，请等待审计完成。', 'DriveSift', 'OK', 'Information')
        return
    }
    try {
        [void][System.Diagnostics.Process]::Start($script:ReportPath)
    }
    catch {
        [void][System.Windows.MessageBox]::Show("无法打开报告：$($_.Exception.Message)", 'DriveSift', 'OK', 'Warning')
    }
})

# 优化建议标签页
$script:el['btnSugAction'].Add_Click({ Invoke-SuggestionAction })

# 隔离区标签页
$script:el['gridQuarantine'].Add_SelectionChanged({ Update-QuarantineButtons })
$script:el['btnQRefresh'].Add_Click({ Load-QuarantineTab })
$script:el['btnQRestore'].Add_Click({ Invoke-RestoreQuarantine })
$script:el['btnQPurge'].Add_Click({ Invoke-PurgeQuarantine })
$script:el['btnQPurgeExpired'].Add_Click({ Invoke-PurgeExpired })

$script:el['cbxRetention'].Add_SelectionChanged({
    $item = $script:el['cbxRetention'].SelectedItem
    if ($item) {
        $days = [int]$item.Tag
        if ($days -ne $script:RetentionDays) {
            Save-RetentionSetting $days
            Set-Status ("新的隔离条目将保留 $days 天；已有条目按移入时的天数执行")
        }
    }
})

$script:el['chkAutoPurge'].Add_Checked({
    if ($script:AutoPurgeGuard) { return }
    $answer = [System.Windows.MessageBox]::Show(
        "将创建 Windows 计划任务（以当前用户身份，每天运行一次）：`n自动永久删除隔离区中已过 $($script:RetentionDays) 天保留期的条目。`n`n删除前仍会做防篡改与尺寸漂移检查，并在 audit.jsonl 留痕；保留期内未被还原的条目不会被跳过保留策略。`n`n确定启用？",
        '启用自动清理', 'YesNo', 'Question')
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
        $script:AutoPurgeGuard = $true
        $script:el['chkAutoPurge'].IsChecked = $false
        $script:AutoPurgeGuard = $false
        return
    }
    try {
        $null = Register-DsAutoPurge -QuarantineRoot $script:QuarantineRoot -RetentionDays $script:RetentionDays -Confirm:$false
        Set-Status '自动清理计划任务已创建' '#41DE8B'
    }
    catch {
        $script:AutoPurgeGuard = $true
        $script:el['chkAutoPurge'].IsChecked = $false
        $script:AutoPurgeGuard = $false
        Set-Status "计划任务创建失败：$($_.Exception.Message)" '#F0685C'
        return
    }
    Update-AutoPurgeState
})

$script:el['chkAutoPurge'].Add_Unchecked({
    if ($script:AutoPurgeGuard) { return }
    $answer = [System.Windows.MessageBox]::Show('将停止自动清理计划任务。到期条目会保留，直到你手动清理。', '停用自动清理', 'YesNo', 'Question')
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
        $script:AutoPurgeGuard = $true
        $script:el['chkAutoPurge'].IsChecked = $true
        $script:AutoPurgeGuard = $false
        return
    }
    try {
        $null = Register-DsAutoPurge -QuarantineRoot $script:QuarantineRoot -Unregister -Confirm:$false
        Set-Status '自动清理计划任务已注销'
    }
    catch {
        $script:AutoPurgeGuard = $true
        $script:el['chkAutoPurge'].IsChecked = $true
        $script:AutoPurgeGuard = $false
        Set-Status "计划任务注销失败：$($_.Exception.Message)" '#F0685C'
        return
    }
    Update-AutoPurgeState
})

$script:el['btnOpenQ'].Add_Click({
    $target = $script:QuarantineRoot
    if (-not (Test-Path -LiteralPath $target)) {
        try {
            New-Item -ItemType Directory -Path $target -Force | Out-Null
        }
        catch {
            Set-Status "无法创建隔离区目录：$($_.Exception.Message)" '#F0685C'
            return
        }
    }
    try {
        [void][System.Diagnostics.Process]::Start('explorer.exe', "`"$target`"")
    }
    catch {
        Set-Status "无法打开目录：$($_.Exception.Message)" '#F0685C'
    }
})

# ---------- 启动 ----------
Update-TierButtons
Reset-Detail
Update-QuarantineButton
$null = Import-Cache

if ($ValidateOnly) {
    # 静态冒烟：不扫描真实目录，用假数据验证三个标签页的绑定与隔离区生命周期
    $fakeCandidate = [pscustomobject]@{
        Id = 'test'; RuleId = 'r'; Name = '验证用示例目录'; Category = '缓存'; Tier = 'P2'
        Paths = @((Join-Path $env:TEMP 'ds-validate-missing')); FileCount = 3
        SizeMB = 12.34; LastWriteUtc = (Get-Date).ToUniversalTime().ToString('s')
        Owner = 'project:test'; Reasons = @('这是静态验证行，未执行任何实际操作')
        Rebuild = '验证：本行仅用于界面绑定测试'; Notes = ''
        ContentChecked = 42; ContentTruncated = $false
        ContentHits = 2; ContentHitKinds = 'documents,images'
        ContentHitSamples = @('memo.docx', 'photo.png')
        ContentTop = 'documents 30 · images 12 · misc 10'
    }
    $fakeHealth = [pscustomobject]@{
        GeneratedAt = (Get-Date).ToString('s')
        Drives = @([pscustomobject]@{ Letter = 'C:'; TotalGB = 500; FreeGB = 120; FreePercent = 24; IsSystem = $true })
        Disks = @([pscustomobject]@{ Name = 'TestDisk'; SizeGB = 500; IsSsd = $true })
        MemoryTotalMB = 16384; MemoryFreeMB = 8192
        StartupItems = @([pscustomobject]@{ Name = 'a'; Command = 'b'; Source = 'c' })
        TopMemoryProcesses = @([pscustomobject]@{ Name = 'test'; MemoryMB = 500 })
        UptimeHours = 12.5; Os = 'Test'; CpuName = 'TestCPU'; CpuLoad = 10
        PowerPlan = '平衡'; Quarantine = $null
    }
    $fakeSuggestion = [pscustomobject]@{
        Id = 'test-sug'; Severity = 'info'
        Title = '验证：建议行绑定'
        Detail = '本行仅用于验证界面绑定，未执行任何实际操作。'
        ActionId = 'taskmgr'
    }

    $script:AllRows = @(New-RowModel $fakeCandidate)
    $script:Duplicates = @()
    $script:Health = $fakeHealth
    $script:Suggestions = @($fakeSuggestion)
    Apply-Filter
    Update-Kpi
    Render-OptTab
    Load-QuarantineTab

    $window.Show()
    [void]$window.UpdateLayout()

    $script:el['gridCandidates'].SelectedIndex = 0
    if ($script:el['detContent'].Visibility -ne 'Visible') { throw '内容抽查区块未显示' }
    $script:el['gridSuggestions'].SelectedIndex = 0
    if ($script:el['btnSugAction'].IsEnabled -ne $true) { throw '建议动作按钮状态错误' }

    # 隔离区生命周期：移入 → 列表 → 还原 → 清单清空
    $fakeQDir = Join-Path $env:TEMP "ds-validate-$(Get-Random)"
    $fakeQ = Join-Path $fakeQDir 'quarantine'
    $fakeSrc = Join-Path $fakeQDir 'src\cache-x'
    New-Item -ItemType Directory -Path $fakeSrc -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fakeSrc 'x.txt') -Value 'validate'
    $qCandidate = [pscustomobject]@{
        Id = 'cache-x'; RuleId = 'r'; Name = '验证隔离区条目'; Tier = 'P2'
        Paths = @($fakeSrc); FileCount = 1; SizeMB = 0.001
        SizeBytes = (Get-Item -LiteralPath (Join-Path $fakeSrc 'x.txt')).Length
        Rebuild = 'n/a'; ContentHits = 0; ContentHitKinds = ''
    }
    $null = Move-DsToQuarantine -Candidate $qCandidate -QuarantineRoot $fakeQ -RetentionDays 3 -Confirm:$false
    $script:QuarantineRoot = $fakeQ
    Load-QuarantineTab
    if (@($script:el['gridQuarantine'].Items).Count -ne 1) { throw '隔离区列表应显示 1 条' }
    $restoreResults = @(Restore-DsQuarantine -QuarantineRoot $fakeQ -All -Confirm:$false)
    if (@($restoreResults | Where-Object { $_.Action -eq 'Restored' }).Count -ne 1) { throw '验证还原未成功' }
    Load-QuarantineTab
    if (@($script:el['gridQuarantine'].Items).Count -ne 0) { throw '还原后隔离区列表应为空' }
    Remove-Item -LiteralPath $fakeQDir -Recurse -Force

    Write-Host 'DriveSift GUI 验证通过：三个标签页、内容抽查展示与隔离区生命周期均正常。'
    $window.Close()
    exit 0
}

# 不自动扫描：有缓存时上方 Import-Cache 已显示上次结果；等用户点击「开始扫描」
if (-not $script:LoadedCache) {
    Set-Status '请选择扫描范围（未选择时默认 C:\），然后点击「开始扫描」开始审计'
}

[void]$window.ShowDialog()
