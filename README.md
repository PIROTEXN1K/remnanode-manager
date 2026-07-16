# RemnaNode Manager

Русский интерактивный установщик и менеджер Remnawave Node для Ubuntu/Debian.

## Возможности

- установка актуального `remnawave/node:latest`;
- постоянная команда `remnanode` и русское меню;
- запуск, остановка, перезапуск и обновление;
- статус контейнера, Xray и ресурсов;
- общие журналы, журналы Xray и фильтр ошибок;
- полная диагностика сети, Docker, портов и BBR;
- UFW: Node API доступен только с IP панели;
- Fail2Ban для SSH и безопасное снятие блокировки;
- BBR и разумные сетевые лимиты;
- ротация Docker-журналов;
- резервные копии перед обновлением и удалением;
- необязательный еженедельный автоперезапуск.

## Будущая однокомандная установка

После публикации файла в GitHub:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/OWNER/REPOSITORY/main/remnanode-manager.sh)
```

Откроется меню. Выберите `1`, затем укажите IP панели, порт Node API и `SECRET_KEY`.

После установки меню открывается короткой командой:

```bash
remnanode
```

Команды для автоматизации:

```bash
remnanode status
remnanode diagnose
remnanode logs
remnanode update
remnanode restart
remnanode backup
```

## Поддерживаемые системы

- Ubuntu 22.04/24.04;
- актуальные Debian с systemd;
- запуск от `root` или через `sudo`.

Сценарий не изменяет пароль SSH и не отключает вход по паролю автоматически, чтобы не лишить владельца доступа к новой VDS.


