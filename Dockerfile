FROM ubuntu:14.04

MAINTAINER Max Rottenkolber (@eugeneia)

RUN apt-get update
RUN apt-get install -y build-essential gcc pkg-config glib-2.0 libglib2.0-dev libsdl1.2-dev libaio-dev libcap-dev libattr1-dev libpixman-1-dev libncurses5 libncurses5-dev git telnet tmux numactl bc debootstrap

RUN mkdir /root/.test_env
COPY src/program/snabbnfv/test_env/assets/* /root/.test_env/
COPY src/scripts/make-assets.sh /

RUN mkdir /hugetlbfs
