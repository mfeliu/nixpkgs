{ config, lib, utils, pkgs, ... }:

with lib;

let

  cfg = config.networking.supplicant;

  # We must escape interfaces due to the systemd interpretation
  subsystemDevice = interface:
    "sys-subsystem-net-devices-${utils.escapeSystemdPath interface}.device";

  serviceName = iface: "supplicant-${if (iface=="WLAN") then "wlan@" else (
                                     if (iface=="LAN") then "lan@" else (
                                     if (iface=="DBUS") then "dbus"
                                     else (replaceChars [" "] ["-"] iface)))}";

  # TODO: Use proper privilege separation for wpa_supplicant
  supplicantService = iface: suppl:
    let
      deps = (if (iface=="WLAN"||iface=="LAN") then ["sys-subsystem-net-devices-%i.device"] else (
             if (iface=="DBUS") then ["dbus.service"]
             else (map subsystemDevice (splitString " " iface))))
             ++ optional (suppl.bridge!="") (subsystemDevice suppl.bridge);

      ifaceArg = concatStringsSep " -N " (map (i: "-i${i}") (splitString " " iface));
      driverArg = optionalString (suppl.driver != null) "-D${suppl.driver}";
      bridgeArg = optionalString (suppl.bridge!="") "-b${suppl.bridge}";
      confFileArg = optionalString (suppl.configFile.path!=null) "-c${suppl.configFile.path}";
      extraConfFile = pkgs.writeText "supplicant-extra-conf-${replaceChars [" "] ["-"] iface}" ''
        ${optionalString suppl.userControlled.enable "ctrl_interface=DIR=${suppl.userControlled.socketDir} GROUP=${suppl.userControlled.group}"}
        ${optionalString suppl.configFile.writable "update_config=1"}
        ${suppl.extraConf}
      '';
    in
      { description = "Supplicant ${iface}${optionalString (iface=="WLAN"||iface=="LAN") " %I"}";
        wantedBy = [ "multi-user.target" ] ++ deps;
        wants = [ "network.target" ];
        bindsTo = deps;
        after = deps;
        before = [ "network.target" ];

        path = [ pkgs.coreutils ];

        preStart = ''
          ${optionalString (suppl.configFile.path!=null && suppl.configFile.writable) ''
            (umask 077 && touch -a "${suppl.configFile.path}")
          ''}
          ${optionalString suppl.userControlled.enable ''
            install -dm770 -g "${suppl.userControlled.group}" "${suppl.userControlled.socketDir}"
          ''}
        '';

        serviceConfig.ExecStart = "${pkgs.wpa_supplicant}/bin/wpa_supplicant -s ${driverArg} ${confFileArg} -I${extraConfFile} ${bridgeArg} ${suppl.extraCmdArgs} ${if (iface=="WLAN"||iface=="LAN") then "-i%I" else (if (iface=="DBUS") then "-u" else ifaceArg)}";

      };


in

{

  ###### interface

  options = {

    networking.supplicant = mkOption {
      type = with types; attrsOf (submodule {
        options = {

          configFile = {

            path = mkOption {
              type = types.nullOr types.path;
              default = null;
              example = literalExpression "/etc/wpa_supplicant.conf";
              description = ''
                External <literal>wpa_supplicant.conf</literal> configuration file.
                The configuration options defined declaratively within <literal>networking.supplicant</literal> have
                precedence over options defined in <literal>configFile</literal>.
              '';
            };

            writable = mkOption {
              type = types.bool;
              default = false;
              description = ''
                Whether the configuration file at <literal>configFile.path</literal> should be written to by
                <literal>wpa_supplicant</literal>.
              '';
            };

          };

          extraConf = mkOption {
            type = types.lines;
            default = "";
            example = ''
              ap_scan=1
              device_name=My-NixOS-Device
              device_type=1-0050F204-1
              driver_param=use_p2p_group_interface=1
              disable_scan_offload=1
              p2p_listen_reg_class=81
              p2p_listen_channel=1
              p2p_oper_reg_class=81
              p2p_oper_channel=1
              manufacturer=NixOS
              model_name=NixOS_Unstable
              model_number=2015
            '';
            description = ''
              Configuration options for <literal>wpa_supplicant.conf</literal>.
              Options defined here have precedence over options in <literal>configFile</literal>.
              NOTE: Do not write sensitive data into <literal>extraConf</literal> as it will
              be world-readable in the <literal>nix-store</literal>. For sensitive information
              use the <literal>configFile</literal> instead.
            '';
          };

          extraCmdArgs = mkOption {
            type = types.str;
            default = "";
            example = "-e/run/wpa_supplicant/entropy.bin";
            description =
              "Command line arguments to add when executing <literal>wpa_supplicant</literal>.";
          };

          driver = mkOption {
            type = types.nullOr types.str;
            default = "nl80211,wext";
            description = "Force a specific wpa_supplicant driver.";
          };

          bridge = mkOption {
            type = types.str;
            default = "";
            description = "Name of the bridge interface that wpa_supplicant should listen at.";
          };

          userControlled = {

            enable = mkOption {
              type = types.bool;
              default = false;
              description = ''
                Allow normal users to control wpa_supplicant through wpa_gui or wpa_cli.
                This is useful for laptop users that switch networks a lot and don't want
                to depend on a large package such as NetworkManager just to pick nearby
                access points.
              '';
            };

            socketDir = mkOption {
              type = types.str;
              default = "/run/wpa_supplicant";
              description = "Directory of sockets for controlling wpa_supplicant.";
            };

            group = mkOption {
              type = types.str;
              default = "wheel";
              example = "network";
              description = "Members of this group can control wpa_supplicant.";
            };

          };
        };
      });

      default = { };

      example = literalExpression ''
        { "wlan0 wlan1" = {
            configFile.path = "/etc/wpa_supplicant.conf";
            userControlled.group = "network";
            extraConf = '''
              ap_scan=1
              p2p_disabled=1
            ''';
            extraCmdArgs = "-u -W";
            bridge = "br0";
          };
        }
      '';

      description = ''
        Interfaces for which to start <command>wpa_supplicant</command>.
        The supplicant is used to scan for and associate with wireless networks,
        or to authenticate with 802.1x capable network switches.

        The value of this option is an attribute set. Each attribute configures a
        <command>wpa_supplicant</command> service, where the attribute name specifies
        the name of the interface that <command>wpa_supplicant</command> operates on.
        The attribute name can be a space separated list of interfaces.
        The attribute names <literal>WLAN</literal>, <literal>LAN</literal> and <literal>DBUS</literal>
        have a special meaning. <literal>WLAN</literal> and <literal>LAN</literal> are
        configurations for universal <command>wpa_supplicant</command> service that is
        started for each WLAN interface or for each LAN interface, respectively.
        <literal>DBUS</literal> defines a device-unrelated <command>wpa_supplicant</command>
        service that can be accessed through <literal>D-Bus</literal>.
      '';

    };

  };


  ###### implementation

  config = mkIf (cfg != {}) {

    environment.systemPackages =  [ pkgs.wpa_supplicant ];

    services.dbus.packages = [ pkgs.wpa_supplicant ];

    systemd.services = mapAttrs' (n: v: nameValuePair (serviceName n) (supplicantService n v)) cfg;

    services.udev.packages = [
      (pkgs.writeTextFile {
        name = "99-zzz-60-supplicant.rules";
        destination = "/etc/udev/rules.d/99-zzz-60-supplicant.rules";
        text = ''
          ${flip (concatMapStringsSep "\n") (filter (n: n!="WLAN" && n!="LAN" && n!="DBUS") (attrNames cfg)) (iface:
            flip (concatMapStringsSep "\n") (splitString " " iface) (i: ''
              ACTION=="add", SUBSYSTEM=="net", ENV{INTERFACE}=="${i}", TAG+="systemd", ENV{SYSTEMD_WANTS}+="supplicant-${replaceChars [" "] ["-"] iface}.service", TAG+="SUPPLICANT_ASSIGNED"''))}

          ${optionalString (hasAttr "WLAN" cfg) ''
            ACTION=="add", SUBSYSTEM=="net", ENV{DEVTYPE}=="wlan", TAG!="SUPPLICANT_ASSIGNED", TAG+="systemd", PROGRAM="${pkgs.systemd}/bin/systemd-escape -p %E{INTERFACE}", ENV{SYSTEMD_WANTS}+="supplicant-wlan@$result.service"
          ''}
          ${optionalString (hasAttr "LAN" cfg) ''
            ACTION=="add", SUBSYSTEM=="net", ENV{DEVTYPE}=="lan", TAG!="SUPPLICANT_ASSIGNED", TAG+="systemd", PROGRAM="${pkgs.systemd}/bin/systemd-escape -p %E{INTERFACE}", ENV{SYSTEMD_WANTS}+="supplicant-lan@$result.service"
          ''}
        '';
      })];

  };

}

