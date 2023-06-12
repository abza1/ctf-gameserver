FROM python:3.8 as gameserver-base
RUN apt-get update && apt-get install -y libmemcached-dev libsystemd-dev postgresql-client && rm -rf /var/lib/apt/lists/*
ADD src /opt/ctf-gameserver/src/
ADD scripts /opt/ctf-gameserver/scripts/
ADD setup.py Makefile /opt/ctf-gameserver/
RUN cd /opt/ctf-gameserver && make ext
RUN mkdir -p /etc/ctf-gameserver
RUN pip install /opt/ctf-gameserver[prod]

FROM gameserver-base as web
RUN pip install uwsgi
RUN mkdir /uploads && chmod -R 777 /uploads
ADD conf/web/prod_settings.py /etc/ctf-gameserver/web/
ADD doc/controller/scoring.sql /scoring.sql
ADD doc/controller/scoreboard_v2.sql /scoreboard_v2.sql
# variable set in docker-compose.yaml takes precedence over this
ENV CTF_IPPATTERN=10.10.%s.1 
EXPOSE 5000
CMD uwsgi --http-socket 0.0.0.0:5000 --module ctf_gameserver.web.wsgi \
        --python-path=/etc/ctf-gameserver/web \
        --env "CTF_IPPATTERN=${CTF_IPPATTERN}" \
        --env "DJANGO_SETTINGS_MODULE=prod_settings" \
        --static-map '/static/admin=/usr/local/lib/python3.8/site-packages/django/contrib/admin/static/admin' \
        --static-map '/static=/usr/local/lib/python3.8/site-packages/ctf_gameserver/web/static'

FROM web as web-init
RUN pip install ansible passlib
COPY ./init/docker-init.sh /bin/
COPY ./init/ansible /ansible/
CMD /bin/docker-init.sh

FROM gameserver-base as submission
RUN useradd -m -U -s /bin/bash ctf-submission
USER ctf-submission
ENTRYPOINT [ "ctf-submission" ]

FROM gameserver-base as controller
RUN useradd -m -U -s /bin/bash ctf-controller
USER ctf-controller
ENTRYPOINT [ "ctf-controller" ]

FROM gameserver-base as checkerbase
RUN apt-get update && apt-get install -y sudo && rm -rf /var/lib/apt/lists/*
RUN useradd -m -U -s /bin/bash ctf-checkermaster
RUN useradd -m -U -s /bin/bash ctf-checkerrunner
ADD examples/checker/sudoers.d/ctf-checker /etc/sudoers.d/
ADD scripts/checker/docker-entrypoint.sh /sbin/
#USER ctf-checkermaster # do this downstream checkers
ENV CTF_SUDOUSER ctf-checkerrunner
ENTRYPOINT [ "/sbin/docker-entrypoint.sh" ]
